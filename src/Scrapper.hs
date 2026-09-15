-- | Run a finite tree of extraction stages, preserving successful work on disk.
module Scrapper where

import Control.Exception (bracket_)
import Control.Monad (unless, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Control.Monad.Trans.State.Strict (StateT (..), get, gets, modify', runStateT)
import Data.Bifunctor (first)
import qualified Data.ByteString as BS
import Data.Either (isRight)
import Data.List (isPrefixOf, nub)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Network.HTTP.Client as HTTP
import System.Directory
import System.Environment (lookupEnv)
import System.FilePath
import System.IO
import System.IO.Error (tryIOError)
import Text.HTML.TagSoup
import Helpers
import Types

-- | Extract a fresh hidden CSRF field; repeated forms may share the same token.
formToken :: String -> [Tag String] -> Either String String
formToken field tags = case nub [fromAttrib "value" tag | tag <- tags
  , tag ~== TagOpen "input" [], fromAttrib "type" tag == "hidden"
  , fromAttrib "name" tag == field, not (null (fromAttrib "value" tag))] of
    [value] -> Right value
    _ -> Left "Login form has no unambiguous CSRF token; check login_csrf_field"

-- | Submit credentials once. If configured, first fetch a fresh CSRF token and
-- session cookies; neither credentials nor tokens are written to disk.
login :: PPM (Either String ())
login = runExceptT $ do
  cfg <- lift get
  case login_path cfg of
    Nothing -> pure ()
    Just path -> do
      let credential key = do
            value <- liftIO $ lookupEnv (login_env_prefix cfg ++ key)
            maybe (throwE ("Missing environment variable: " ++ login_env_prefix cfg ++ key)) pure value
      username <- credential "LOGIN"
      password <- credential "PASS"
      hidden <- case login_csrf_field cfg of
        Nothing -> pure []
        Just field -> do
          page <- ExceptT (openURL path)
          token <- either throwE pure (formToken field (canonicalizeTags (parseTags page)))
          pure [(field, token)]
      ExceptT $ request path (Just (hidden ++ [(login_arg_login cfg, username), (login_arg_pass cfg, password)])) (\reader -> HTTP.brConsume reader >> pure ())

-- | Select elements whose whitespace-separated class list contains the class.
tag_class_f :: String -> String -> (Tag String -> a) -> [Tag String] -> [a]
tag_class_f tag cls f = map f . filter (\t -> t ~== TagOpen tag [] && cls `elem` words (fromAttrib "class" t))

-- | Fetch canonicalized HTML tags, rejecting a recognizable login page.
extracturl :: URLString -> PPM (Either String [Tag String])
extracturl target = do
  result <- fmap (canonicalizeTags . parseTags) <$> openURL target
  marker <- gets login_needed_tag
  pure $ result >>= \tags -> if any (~== marker) tags
    then Left "Login page received; check credentials and the site's login flow"
    else Right tags

-- | Stream a body instead of retaining a whole download in memory.
copyBody :: HTTP.BodyReader -> Handle -> IO ()
copyBody reader output = do
  chunk <- reader
  unless (BS.null chunk) $ BS.hPut output chunk >> copyBody reader output

-- | Copy a cached file using bounded chunks.
copyHandle :: Handle -> Handle -> IO ()
copyHandle input = copyBody (BS.hGetSome input 32768)

-- | Download or copy a known cached URL, then record success. Existing unknown
-- files and symlinks are never replaced. Call within 'mainLoop' for its lock.
download :: UrlWithDest -> PPM (Either String ())
download = downloadWith copyBody

-- | Validate/consume a response before committing it to disk or the URL cache.
-- The consumer must throw on invalid content and stream the complete valid body.
downloadWith :: (HTTP.BodyReader -> Handle -> IO ()) -> UrlWithDest -> PPM (Either String ())
downloadWith consume node = runExceptT $ do
  address <- ExceptT (mkurl (url node))
  cfg <- lift get
  let root = download_folder cfg
      path = dest node
      relative = makeRelative root path
      io = ExceptT . liftIO . ioEither
  io $ checkOutput root path
  exists <- io $ doesPathExist path
  if exists
    then unless ((address, relative) `elem` alreadies_urls cfg) $
      throwE ("Refusing existing untracked file: " ++ path)
    else do
      io $ createDirectoryIfMissing True (takeDirectory path)
      cached <- lift $ handle_url_cache address
      source <- case cached of
        Nothing -> pure Nothing
        Just saved -> do
          let original = root </> saved
          io $ checkOutput root original
          present <- io $ doesFileExist original
          pure (if present then Just original else Nothing)
      case source of
        Just original -> io $ withBinaryFile original ReadMode $ \input -> atomicWrite path (copyHandle input)
        Nothing -> ExceptT $ request address Nothing (\reader -> atomicWrite path (consume reader))
      -- Append only after the completed file is in place.
      io $ BS.appendFile (root </> urlsfile cfg) (T.encodeUtf8 (T.pack (show (address, relative) ++ "\n")))
      lift $ modify' (\state -> state {alreadies_urls = (address, relative) : alreadies_urls state})

-- | Download selected links relative to their containing page, plus that page.
-- Use an empty second argument when adapting this helper into a stage.
downloader :: [[Tag String] -> [URLString]] -> FilePath -> UrlWithDest -> PPM (Either String ())
downloader generators directory node = runExceptT $ do
  page <- ExceptT (mkurl (url node))
  tags <- ExceptT (extracturl page)
  let links = nub (filter (not . null) (concatMap ($ tags) generators))
      output = directory </> dest node
  when (null links) $ throwE "No download links found; check the selectors"
  addresses <- either throwE pure (traverse (resolveURL page) (links ++ [page]))
  unless (length (nub (map url_basename addresses)) == length (nub addresses)) $
    throwE "Different URLs map to the same filename; use explicit destinations with download"
  mapM_ (\address -> ExceptT (download (UrlWithDest address (output </> url_basename address)))) addresses

-- | Resolve children and reject ambiguous or escaping destination paths.
prepareChildren :: UrlWithDest -> [UrlWithDest] -> Either String [UrlWithDest]
prepareChildren parent children = do
  resolved <- nub <$> traverse prepare children
  unless (length (nub (map dest resolved)) == length resolved) $ Left "Duplicate child destination"
  pure resolved
  where
    prepare child = do
      unless (safeRelative (dest child) && normalise (dest child) /= "."
              && not (any (".scraper-" `isPrefixOf`) (splitDirectories (dest child)))) $
        Left ("Unsafe child destination: " ++ dest child)
      address <- resolveURL (url parent) (url child)
      pure child {url = address, dest = dest parent </> normalise (dest child)}

-- | Convert an adapter's IO exceptions to stage failures without catching Ctrl-C.
attempt :: Stage -> Stage
attempt stage node = StateT $ \cfg -> do
  result <- tryIOError (runStateT (stage node) cfg)
  pure $ either (\err -> (Left (show err), cfg)) id result

-- | A node is finished only after its stage and all descendants succeed.
ff :: UrlWithDest -> [Stage] -> PPM [ErrorDetails]
ff _ [] = pure []
ff node (stage : rest) = do
  outcome <- runExceptT $ do
    cfg <- lift get
    let directory = dest node
        marker = directory </> finishedfile cfg
        identity = T.encodeUtf8 (T.pack (show (url node, length rest)))
        io = ExceptT . liftIO . ioEither
    io $ checkOutput (download_folder cfg) directory
    io $ createDirectoryIfMissing True directory
    io $ checkOutput (download_folder cfg) marker
    done <- io $ doesFileExist marker
    if done
      then do
        previous <- io $ BS.readFile marker
        unless (previous == identity) $ throwE "Completion marker belongs to a different URL or pipeline; choose a new output directory"
        pure []
      else do
        children <- ExceptT $ first snd <$> retry (retry_count cfg) (url node) (attempt stage node)
        when (null children && not (null rest)) $ throwE "No child links found before the final stage"
        when (not (null children) && null rest) $ throwE "Final stage returned unprocessed child links"
        next <- either throwE pure (prepareChildren node children)
        answers <- lift $ concat <$> mapM (`ff` rest) next
        when (all isRight answers) $ io $ writeOutput (download_folder cfg) marker identity
        pure answers
  pure (either (\err -> [Left (url node, err)]) id outcome)

-- | Run one crawl per directory. Return False on any error; leave successful
-- subtrees intact for the next invocation. The CLI maps False to exit status 1.
mainLoop :: Config -> [Stage] -> IO Bool
mainLoop config stages = do
  result <- ioEither $ do
    cfg <- createConfig config
    address <- either (ioError . userError) pure (resolveURL (base cfg) "")
    when (null stages) $ ioError (userError "The pipeline has no stages")
    let root = download_folder cfg
        lock = root </> ".scraper-lock"
    checkOutput root lock
    bracket_ (createDirectory lock) (removeDirectory lock) $ do
      checkOutput root (root </> urlsfile cfg)
      writeOutput root (root </> ".scraper-source") (T.encodeUtf8 (T.pack address))
      loaded <- loadCache cfg
      let run = do
            authenticated <- login
            case authenticated of
              Left err -> pure [Left ("Login", err)]
              Right () -> ff (UrlWithDest address root) stages
      fst <$> runStateT run loaded
  case result of
    Left err -> hPutStrLn stderr err >> pure False
    Right errors -> do
      mapM_ (either (\(context, err) -> hPutStrLn stderr (context ++ ": " ++ err)) pure) errors
      let ok = all isRight errors
      putStrLn (if ok then "Scrape completed." else "Scrape incomplete; successful subtrees can be resumed.")
      pure ok

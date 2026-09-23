{-# LANGUAGE OverloadedStrings #-}
-- | Metadata and relative navigation links over the existing flat catalogue.
module AmeriLinguaIndex where

import qualified AmeriLingua as Ameri
import AmeriLinguaContent (plain)
import Control.Monad (unless, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Control.Monad.Trans.State.Strict (gets)
import Data.Aeson (Value, encode, eitherDecodeStrict', object, withObject, (.:), (.:?), (.!=), (.=))
import Data.Aeson.Types (parseEither)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LB
import Data.List (isPrefixOf, nub)
import Data.String (fromString)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.IO as TIO
import Network.URI (parseURIReference, uriPath)
import System.Directory
import System.FilePath
import System.IO (hPutStrLn, stderr)
import System.IO.Error (catchIOError, isDoesNotExistError)
import Paths_haskellwebscrapper (getDataFileName)
import Text.HTML.TagSoup (Tag (..))
import Text.HTML.TagSoup.Tree (TagTree (..), tagTree, universeTree)
import Text.Printf (printf)
import Helpers
import Scrapper
import Types

config :: Config
config = Ameri.config {finishedfile = ".scraper-index-finished"}

stages :: Config -> [Stage]
stages _ = [discover, saveNode]

navigation :: FilePath
navigation = "_navigation"

-- | Keep multi-valued facets separate; IDs and durations remain scalar metadata.
facets :: [String]
facets = ["category", "level", "topic", "grammar", "focus", "media"]

data Metadata = Metadata String [(String, String)] deriving (Eq, Show)

parseMetadata :: [Tag String] -> Either String Metadata
parseMetadata tags = do
  let trees = tagTree tags
      titles = nub [plain children | TagBranch "h1" _ children <- universeTree trees, not (null (plain children))]
      items = concatMap (Ameri.blocks ["info_item"]) (Ameri.blocks ["info"] trees)
      known = [("category", "category"), ("level", "level"), ("topic", "topic")
        , ("grammar", "grammar"), ("focus", "focus"), ("media", "media")
        , ("lesson id", "lesson_id"), ("lesson time", "lesson_time")]
      fields = nub [(key, value) | children <- items
        , let label = T.unpack (T.toLower (T.pack (plain [t | t@(TagLeaf (TagText _)) <- children])))
        , Just key <- [lookup label known]
        , let value = plain (concat [body | TagBranch "span" _ body <- children])
        , not (null value)]
  unless (length (nub (map fst fields)) == length fields) $ Left "Conflicting lesson metadata fields"
  unless (all (`elem` map fst fields) ["category", "level"]) $ Left "Missing Category or Level in .info .info_item"
  case titles of
    [title] -> Right (Metadata title fields)
    _ -> Left "Expected one nonempty lesson title"

values :: String -> [String]
values = nub . filter (not . null) . map (T.unpack . T.strip) . T.splitOn "," . T.pack

-- | Sequence URLs come from the hub, rather than inferred lesson metadata.
parseHub :: URLString -> [Tag String] -> Either String [UrlWithDest]
parseHub parent tags = do
  let refs = nub [Ameri.attribute "href" attrs | (attrs, _) <- Ameri.anchors (tagTree tags)
        , Just path <- [uriPath <$> parseURIReference (Ameri.attribute "href" attrs)]
        , "/lesson-sequences-" `isPrefixOf` path]
  addresses <- traverse (resolveURL parent) refs
  when (null addresses) $ Left "No Lesson Sequences links found on the hub"
  unless (all (sameOrigin parent) addresses) $ Left "Sequence link leaves the configured origin"
  pure [UrlWithDest address (navigation </> "sequences" </> group slug </> mkname slug)
       | address <- addresses, let slug = drop (length ("lesson-sequences-" :: String)) (url_basename address)]
  where
    group slug | any (`isPrefixOf` slug) ["business-english-", "interview-prep-"] = "Business_English"
               | otherwise = "General_English"

data Sequence = Sequence String String [(String, URLString, String)] deriving (Eq, Show)

-- | The section owns an h2 and ordered cards; each card owns an h3 and lesson link.
parseSequence :: URLString -> [Tag String] -> Either String Sequence
parseSequence parent tags = do
  let sections = [(plain title, children, cards) | TagBranch "div" _ children <- universeTree (tagTree tags)
        , TagBranch "h2" _ title <- children
        , let cards = [body | TagBranch "div" _ body <- children, any isHeading body]
        , not (null cards)]
  case sections of
    [(title, children, cards)] -> do
      entries <- traverse entry cards
      pure (Sequence title (plain [p | p@(TagBranch "p" _ _) <- children]) entries)
    _ -> Left "Expected one sequence section with h2 and ordered h3 lesson cards"
  where
    isHeading (TagBranch "h3" _ _) = True
    isHeading _ = False
    entry children = do
      let titles = [plain body | TagBranch "h3" _ body <- children]
          refs = nub [Ameri.attribute "href" attrs | (attrs, _) <- Ameri.anchors children
            , Just path <- [uriPath <$> parseURIReference (Ameri.attribute "href" attrs)]
            , "/esl-lesson-plans/" `isPrefixOf` path]
          description = plain [p | p@(TagBranch "p" _ body) <- children
            , not (any ((`elem` refs) . Ameri.attribute "href" . fst) (Ameri.anchors body))]
      case (titles, refs) of
        ([title], [ref]) | not (null title) -> do
          address <- resolveURL parent ref
          unless (sameOrigin parent address && Ameri.isLesson address) $ Left "Sequence lesson leaves the configured origin"
          pure (title, address, description)
        _ -> Left "Sequence card must contain one title and one lesson link"

-- | Reject symlink ancestors as well as the directory itself before creating links.
directory :: FilePath -> FilePath -> IO ()
directory root path = do
  let relative = makeRelative root path
  unless (path == root || safeRelative relative) $ ioError (userError "Navigation directory escapes the catalogue")
  mapM_ (\part -> checkOutput root part >> createDirectoryIfMissing False part)
    (drop 1 (scanl (</>) root (filter (/= ".") (splitDirectories relative))))

-- | Idempotent relative links; never replace a regular file or a different link.
linkLesson :: FilePath -> FilePath -> FilePath -> IO ()
linkLesson root path target = do
  checkOutput root target
  present <- doesDirectoryExist target
  unless present $ ioError (userError ("Missing lesson directory: " ++ target))
  directory root (takeDirectory path)
  let depth = length (filter (/= ".") (splitDirectories (makeRelative root (takeDirectory path))))
      relative = joinPath (replicate depth "..") </> makeRelative root target
  symbolic <- pathIsSymbolicLink path `catchIOError` \err ->
    if isDoesNotExistError err then pure False else ioError err
  if symbolic then do
    previous <- getSymbolicLinkTarget path
    unless (previous == relative) $ ioError (userError ("Refusing different navigation link: " ++ path))
  else do
    exists <- doesPathExist path
    when exists $ ioError (userError ("Refusing existing navigation entry: " ++ path))
    createDirectoryLink relative path

writeText :: FilePath -> FilePath -> String -> IO ()
writeText root path = writeOutput root path . T.encodeUtf8 . T.pack

-- | Discover both kinds of page first; the ordinary crawler retries/checkpoints them.
discover :: Stage
discover node = runExceptT $ do
  when (Ameri.isLesson (url node)) $ throwE "amerilingua-index needs the catalogue URL and its flat output directory"
  lessons <- ExceptT (Ameri.findLessons node)
  when (navigation `elem` map dest lessons) $ throwE "A lesson name collides with the navigation directory"
  hub <- either throwE pure (resolveURL (url node) "/lesson-sequences")
  page <- ExceptT (extracturl hub)
  sequences <- either throwE pure (parseHub hub page)
  let root = dest node
      index = root </> navigation
  ExceptT $ liftIO $ ioEither $ do
    directory root index
    mapM_ (directory root . (index </>) . ("tags" </>)) facets
    -- Validate all ancestors before the generic crawler creates sequence nodes.
    mapM_ (directory root . (root </>) . dest) sequences
    writeText root (index </> "catalogue-urls.txt") (unlines (map url lessons))
    writeText root (index </> "README.md") $ "# AmeriLingua catalogue\n\nSource: " ++ url node
      ++ "\n\n## Tags\n\n" ++ unlines ["- [" ++ key ++ "](tags/" ++ key ++ "/)" | key <- facets]
      ++ "\n## Lesson Sequences\n\n" ++ unlines ["- [" ++ takeFileName (takeDirectory (dest item)) ++ " / "
        ++ takeFileName (dest item) ++ "](" ++ makeRelative navigation (dest item) ++ "/README.md)" | item <- sequences]
      ++ "\nLessons stay in their original folders. All navigation links are relative.\n"
  pure (lessons ++ sequences)

saveNode :: Stage
saveNode node = runExceptT $ do
  liftIO $ hPutStrLn stderr ("Catalogue index: " ++ url node)
  page <- ExceptT (extracturl (url node))
  root <- lift (gets download_folder)
  if Ameri.isLesson (url node) then do
    metadata <- either throwE pure (parseMetadata page)
    ExceptT $ liftIO $ ioEither $ saveMetadata root node metadata
  else do
    sequencePage <- either throwE pure (parseSequence (url node) page)
    ExceptT $ liftIO $ ioEither $ saveSequence root node sequencePage
  pure []

saveMetadata :: FilePath -> UrlWithDest -> Metadata -> IO ()
saveMetadata root node (Metadata title fields) = do
  writeText root (dest node </> "source.txt") (url node ++ "\n")
  let json = object (["title" .= title, "source" .= url node]
        ++ [if key `elem` facets then fromString key .= values value else fromString key .= value | (key, value) <- fields])
  writeOutput root (dest node </> "metadata.json") (LB.toStrict (encode json) <> "\n")
  mapM_ tag [(key, value) | (key, field) <- fields, key `elem` facets, value <- values field]
  where
    tag (key, value) = do
      let folder = root </> navigation </> "tags" </> key </> mkname value
      directory root folder
      -- A readable slug collision must fail rather than merge unrelated tags.
      writeText root (folder </> "label.txt") (value ++ "\n")
      linkLesson root (folder </> takeFileName (dest node)) (dest node)

saveSequence :: FilePath -> UrlWithDest -> Sequence -> IO ()
saveSequence root node (Sequence title introduction entries) = do
  directory root (dest node)
  let catalogue = root </> navigation </> "catalogue-urls.txt"
  checkOutput root catalogue
  expected <- lines . T.unpack . T.decodeUtf8 <$> BS.readFile catalogue
  sections <- traverse (save expected) (zip [1 :: Int ..] entries)
  writeText root (dest node </> "README.md") ("# " ++ title ++ "\n\nSource: " ++ url node
    ++ "\n\n" ++ introduction ++ "\n\n" ++ concat sections)
  where
    save expected (position, (heading, address, description)) = do
      let target = root </> url_basename address
          source = target </> "source.txt"
          name = printf "%03d-" position ++ url_basename address
      checkOutput root target
      checkOutput root source
      present <- doesFileExist source
      local <- if present then (== T.encodeUtf8 (T.pack (address ++ "\n"))) <$> BS.readFile source else pure False
      when (present && not local) $ ioError (userError ("Lesson directory belongs to another URL: " ++ target))
      when (not local && address `elem` expected) $ ioError (userError ("Catalogue lesson not yet indexed: " ++ address))
      if local then linkLesson root (dest node </> name) target
        else hPutStrLn stderr ("Sequence lesson absent from this catalogue: " ++ address)
      pure ("## " ++ heading ++ "\n\n"
        ++ (if local then "[Local lesson](" ++ name ++ "/) · " else "Not in this catalogue. ")
        ++ "[Online lesson](" ++ address ++ ")\n\n" ++ description ++ "\n\n")

-- | Embed the indexed JSON in a standalone page; file:// browsers cannot fetch it.
writePage :: Config -> IO ()
writePage cfg = do
  root <- canonicalizePath (download_folder cfg)
  let catalogue = root </> navigation </> "catalogue-urls.txt"
  checkOutput root catalogue
  addresses <- lines . T.unpack . T.decodeUtf8 <$> BS.readFile catalogue
  when (null addresses) $ ioError (userError "Catalogue has no indexed lessons")
  lessons <- traverse (readLesson root) addresses
  template <- getDataFileName "assets/amerilingua-catalogue.html" >>= TIO.readFile
  let marker = "<!-- CATALOGUE_DATA -->"
  unless (T.count marker template == 1) $ ioError (userError "Invalid catalogue page template")
  -- Escaping '<' prevents lesson metadata from terminating the JSON script element.
  let payload = T.replace "<" "\\u003c" (T.decodeUtf8 (LB.toStrict (encode lessons)))
      page = T.replace marker ("<script id=\"catalogue-data\" type=\"application/json\">" <> payload <> "</script>") template
  writeOutput root (root </> "index.html") (T.encodeUtf8 page)

readLesson :: FilePath -> URLString -> IO Value
readLesson root address = do
  let folder = url_basename address
      source = root </> folder </> "source.txt"
      metadata = root </> folder </> "metadata.json"
  unless (safeRelative folder && takeFileName folder == folder) $
    ioError (userError ("Unsafe indexed lesson folder: " ++ folder))
  mapM_ (checkOutput root) [source, metadata]
  saved <- BS.readFile source
  unless (saved == T.encodeUtf8 (T.pack (address ++ "\n"))) $
    ioError (userError ("Indexed lesson belongs to another URL: " ++ folder))
  bytes <- BS.readFile metadata
  entry <- either (ioError . userError . ("Invalid lesson metadata " ++ folder ++ ": " ++)) pure
    (eitherDecodeStrict' bytes)
  let fields = withObject "lesson metadata" $ \o ->
        (,) <$> o .: "title" <*> o .: "source"
          <* traverse (\key -> o .:? fromString key .!= ([] :: [String])) facets
  case (parseEither fields entry :: Either String (String, String)) of
    Right (title, origin) | not (null title) && origin == address ->
      pure (object ["folder" .= folder, "metadata" .= entry])
    _ -> ioError (userError ("Invalid title, source or tags in lesson metadata: " ++ folder))

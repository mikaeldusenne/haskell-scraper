{-# LANGUAGE OverloadedStrings #-}
-- | AmeriLingua catalogue -> lessons -> PDF files and external resource links.
module AmeriLingua where

import Control.Monad (unless, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Control.Monad.Trans.State.Strict (gets)
import qualified Data.ByteString as BS
import Data.List (isPrefixOf, isSuffixOf, nub)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Network.HTTP.Client as HTTP
import Network.URI (URI (..), parseURI, parseURIReference)
import System.FilePath ((</>))
import System.IO (Handle)
import Text.HTML.TagSoup (Tag (..))
import Text.HTML.TagSoup.Tree (TagTree (..), tagTree, universeTree)
import Helpers
import Scrapper
import Types

-- | Email/password login with Laravel's fresh form token and session cookies.
config :: Config
config = defaultconfig
  { base = "https://www.amerilingua.com/esl-lesson-plans"
  , download_folder = "amerilingua_downloads"
  , login_path = Just "/login"
  , login_arg_login = "email", login_arg_pass = "password"
  , login_env_prefix = "AMERILINGUA_", login_csrf_field = Just "_token"
  }

-- | A catalogue walks its pages; a lesson URL downloads only that lesson.
stages :: Config -> [Stage]
stages cfg = if isLesson (base cfg) then [saveLesson] else [findLessons, saveLesson]

-- | Recognize an individual lesson, including URLs supplied with --base-url.
isLesson :: URLString -> Bool
isLesson address = maybe False (\uri -> "/esl-lesson-plans/" `isPrefixOf` uriPath uri
  && uriPath uri /= "/esl-lesson-plans/") (parseURI address)

-- | Select subtrees by class tokens, independently of class order or extra classes.
blocks :: [String] -> [TagTree String] -> [[TagTree String]]
blocks classes trees = [children | TagBranch _ attrs children <- universeTree trees
  , all (`elem` words (attribute "class" attrs)) classes]

-- | Trim surrounding HTML attribute whitespace before parsing hrefs or fragments.
attribute :: String -> [(String, String)] -> String
attribute key = maybe "" (T.unpack . T.strip . T.pack) . lookup key

-- | Anchor attributes and text, restricted to the supplied subtree.
anchors :: [TagTree String] -> [([(String, String)], String)]
anchors trees = [(attrs, concatMap content children) | TagBranch "a" attrs children <- universeTree trees]
  where
    content (TagLeaf (TagText value)) = value
    content (TagBranch _ _ children) = concatMap content children
    content _ = ""

-- | Extract lesson links and the visible next-page control; reject empty layouts.
parseIndex :: URLString -> [Tag String] -> Either String ([UrlWithDest], Maybe URLString)
parseIndex parent tags = do
  let trees = tagTree tags
      refs = nub [attribute "href" attrs | subtree <- blocks ["lesson-item", "row"] trees
        , (attrs, _) <- anchors subtree, not (null (attribute "href" attrs))]
      nextRefs = nub [attribute "href" attrs | (attrs, label) <- anchors trees
        , "next" `elem` words (attribute "rel" attrs)
          || T.strip (T.pack label) `elem` ["»", "›", "Next"]]
  addresses <- filter isLesson <$> traverse (resolveURL parent) refs
  when (null addresses) $ Left "No AmeriLingua lessons found; check the page, session and lesson-item selector"
  unless (all (sameOrigin parent) addresses) $ Left "Lesson link leaves the catalogue origin"
  next <- case nextRefs of
    [] -> Right Nothing
    [ref] -> do
      address <- resolveURL parent ref
      unless (sameOrigin parent address && fmap uriPath (parseURI parent) == fmap uriPath (parseURI address)) $
        Left "Pagination link leaves the catalogue"
      Right (Just address)
    _ -> Left "Ambiguous AmeriLingua next-page links"
  pure (map (\address -> UrlWithDest address (url_basename address)) (nub addresses), next)

-- | Discover the catalogue sequentially. Cycles and more than 200 index pages
-- fail explicitly; a broken later page cannot silently produce a partial catalogue.
findLessons :: Stage
findLessons node = runExceptT (go [] (url node))
  where
    go visited address = do
      when (address `elem` visited) $ throwE "AmeriLingua pagination cycle"
      when (length visited >= 200) $ throwE "AmeriLingua pagination exceeds 200 pages; use a narrower catalogue URL"
      tags <- ExceptT (extracturl address)
      (lessons, next) <- either throwE pure (parseIndex address tags)
      -- Check access before spending requests on the rest of the catalogue.
      case (visited, lessons) of
        ([], firstLesson : _) -> do
          page <- ExceptT (extracturl (url firstLesson))
          either throwE (const (pure ())) (parseResources (url firstLesson) page)
        _ -> pure ()
      following <- maybe (pure []) (go (address : visited)) next
      pure (nub (lessons ++ following))

-- | Read every resource button. Same-origin lesson-file links are PDFs;
-- external HTTP(S) links are preserved, including Google Slides fragments.
parseResources :: URLString -> [Tag String] -> Either String ([UrlWithDest], [URLString])
parseResources parent tags = do
  let items = concatMap (blocks ["lesson-files-item"]) (blocks ["lesson-files"] (tagTree tags))
      refs = [map (attribute "href" . fst) (anchors item) | item <- items]
  when (null refs || any null refs || any (any (\ref -> null ref || "#" `isPrefixOf` ref)) refs) $
    Left "Lesson files are locked or missing; check AMERILINGUA_LOGIN/PASS and your subscription"
  links <- nub <$> traverse (resourceURL parent) (concat refs)
  let local = filter (sameOrigin parent) links
  when (null local) $ Left "No downloadable AmeriLingua PDF links found"
  unless (all (maybe False (isPrefixOf "/lesson-file/" . uriPath) . parseURI) local) $
    Left "Unexpected AmeriLingua resource URL; check the lesson-files selector"
  let pdfs = map (\address -> UrlWithDest address (pdfName address)) local
  unless (length (nub (map dest pdfs)) == length pdfs) $ Left "Different lesson files map to the same filename"
  pure (pdfs, links)
  where
    pdfName address = let name = url_basename address in
      if ".pdf" `isSuffixOf` name then name
      else if "_file_pdf" `isSuffixOf` name then take (length name - length ("_file_pdf" :: String)) name ++ ".pdf"
      else name ++ ".pdf"

-- | Resolve a resource link while retaining its client-side fragment.
resourceURL :: URLString -> URLString -> Either String URLString
resourceURL parent ref = do
  address <- resolveURL parent ref
  pure (address ++ maybe "" uriFragment (parseURIReference ref))

-- | Reject HTML/login responses before any file or successful cache entry exists.
copyPDF :: HTTP.BodyReader -> Handle -> IO ()
copyPDF reader output = do
  prefix <- header BS.empty
  unless ("%PDF-" `BS.isPrefixOf` prefix) $
    ioError (userError "Expected PDF content; the session may have expired or access was denied")
  BS.hPut output prefix
  copyBody reader output
  where
    header bytes | BS.length bytes >= 5 = pure bytes
    header bytes = do
      chunk <- reader
      if BS.null chunk then pure bytes else header (bytes <> chunk)

-- | Save every PDF and an index of all resource links, with one folder per lesson.
saveLesson :: Stage
saveLesson node = runExceptT $ do
  tags <- ExceptT (extracturl (url node))
  (pdfs, links) <- either throwE pure (parseResources (url node) tags)
  mapM_ (\file -> ExceptT (downloadWith copyPDF file {dest = dest node </> dest file})) pdfs
  root <- lift (gets download_folder)
  ExceptT $ liftIO $ ioEither $ mapM_ (\(name, value) ->
    writeOutput root (dest node </> name) (T.encodeUtf8 (T.pack value)))
    [("source.txt", url node ++ "\n"), ("links.txt", unlines links)]
  pure []

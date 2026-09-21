{-# LANGUAGE OverloadedStrings #-}
-- | Add lesson text, pronunciation MP3s and stable media links to an existing crawl.
module AmeriLinguaContent where

import qualified AmeriLingua as Ameri
import Control.Monad (unless, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Control.Monad.Trans.State.Strict (gets)
import Data.Bifunctor (first)
import Data.Bits ((.&.))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base64 as Base64
import Data.Char (isSpace)
import Data.List (nub)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Network.HTTP.Client as HTTP
import Network.URI (parseURI, uriPath)
import System.FilePath ((</>))
import System.IO (Handle, hPutStrLn, stderr)
import Text.HTML.TagSoup (Tag (..))
import Text.HTML.TagSoup.Tree (TagTree (..), tagTree, universeTree)
import Helpers
import Types
import Scrapper

-- | Separate completion markers let this pass enrich already-completed PDF folders.
config :: Config
config = Ameri.config {finishedfile = ".scraper-content-finished"}

-- | Use the same catalogue and single-lesson routing as the PDF adapter.
stages :: Config -> [Stage]
stages cfg = if Ameri.isLesson (base cfg) then [saveContent] else [Ameri.findLessons, saveContent]

-- | Readable lesson text plus separately downloadable media.
data Content = Content
  { markdown :: String
  , audioFiles :: [UrlWithDest]
  , videoURLs :: [URLString] -- ^ Both Video and Audio embeds; name retained for compatibility.
  } deriving (Eq, Show)

-- | Plain text with paragraph/list breaks; omit scripts and player controls.
plain :: [TagTree String] -> String
plain = T.unpack . T.intercalate "\n\n" . filter (not . T.null)
  . map (T.unwords . T.words) . T.lines . T.pack . concatMap render
  where
    render (TagLeaf (TagText value)) = map (\c -> if isSpace c then ' ' else c) value
    render (TagLeaf (TagOpen "br" _)) = "\n"
    render (TagBranch name attrs children)
      | name `elem` ["script", "style", "iframe", "video", "audio", "source", "button"]
        || "audio-player" `elem` words (Ameri.attribute "class" attrs)
        || (name == "a" && "javascript:" `T.isPrefixOf` T.pack (Ameri.attribute "href" attrs)) = ""
      | name == "br" = "\n"
      | name == "li" = "\n- " ++ concatMap render children ++ "\n"
      | otherwise = concatMap render children ++ if name `elem` ["p", "div", "ul", "ol"] then "\n" else ""
    render _ = ""

-- | Match authored section headings; absent sections are optional, empty ones fail.
parseContent :: URLString -> [Tag String] -> Either String Content
parseContent parent tags = do
  let sections = [(plain heading, concat (Ameri.blocks ["desc"] children))
        | children <- Ameri.blocks ["content-item"] (tagTree tags)
        , TagBranch "h2" _ heading <- children
        , plain heading `elem` ["Lesson Objectives", "Video", "Video Transcript", "Audio", "Audio Transcript", "Vocabulary and Pronunciation"]]
  when (null sections) $ Left "No supported lesson content sections; check the session and content-item layout"
  rendered <- traverse section sections
  let audios = nub (concatMap (\(_, files, _) -> files) rendered)
      videos = nub (concatMap (\(_, _, links) -> links) rendered)
  unless (length (nub (map dest audios)) == length audios) $ Left "Different pronunciation URLs map to the same filename"
  pure (Content ("# Lesson material\n\nSource: " ++ parent ++ "\n\n" ++ concatMap (\(body, _, _) -> body) rendered) audios videos)
  where
    section (heading, trees) = do
      let players = [(plain children, Ameri.attribute "data-play" attrs)
            | TagBranch _ _ children <- universeTree trees, TagBranch _ attrs _ <- children
            , "audio-player" `elem` words (Ameri.attribute "class" attrs)]
          media = [attrs | TagBranch name attrs _ <- universeTree trees, name `elem` ["iframe", "video", "audio", "source"]]
               ++ [attrs | TagLeaf (TagOpen name attrs) <- universeTree trees, name == "source"]
          refs = [Ameri.attribute "src" attrs | attrs <- media, not (null (Ameri.attribute "src" attrs))]
      when (any (null . fst) players) $ Left "Pronunciation player has no vocabulary label"
      audios <- traverse (pronunciation . snd) players
      videos <- if heading `elem` ["Video", "Audio"] then nub <$> traverse (Ameri.resourceURL parent) refs else Right []
      when (null videos && (heading == "Video" || (heading == "Audio" && null audios))) $
        Left (heading ++ " section has no supported media URL")
      let body = if heading `elem` ["Vocabulary and Pronunciation", "Audio"] && not (null players)
                 then unlines ["- " ++ unwords (words label) ++ " ([pronunciation](" ++ dest file ++ "))"
                       | ((label, _), file) <- zip players audios]
                 else plain trees
      when (null body && null videos) $ Left ("Empty lesson section: " ++ heading)
      pure ("## " ++ heading ++ "\n\n" ++ body ++ "\n\n" ++ concatMap (\address -> heading ++ ": " ++ address ++ "\n\n") videos, audios, videos)
    pronunciation ref = do
      address <- resolveURL parent ref
      unless (sameOrigin parent address) $ Left "Pronunciation link leaves the lesson origin"
      case maybe [] (T.splitOn "/" . T.pack . uriPath) (parseURI address) of
        "" : "lesson-audio" : ident : _ | not (T.null ident) && T.all (\c -> c >= '0' && c <= '9') ident ->
          Right (UrlWithDest address ("audio" </> T.unpack ident ++ ".mp3"))
        _ -> Left "Unexpected pronunciation URL; expected /lesson-audio/<id>/..."

-- | Accept raw MP3 or the site's base64 body, rejecting HTML and corrupt encodings.
decodeAudio :: BS.ByteString -> Either String BS.ByteString
decodeAudio bytes = do
  decoded <- if mp3 bytes then Right bytes else
    first (const "Invalid base64 pronunciation audio") (Base64.decode (BS.filter (`notElem` [9, 10, 13, 32]) bytes))
  if mp3 decoded then Right decoded else Left "Expected MP3 pronunciation audio; the session may have expired"
  where
    mp3 value = "ID3" `BS.isPrefixOf` value || case BS.unpack (BS.take 2 value) of
      [255, flags] -> flags .&. 224 == 224 && flags .&. 24 /= 8 && flags .&. 6 == 2
      _ -> False

-- | Pronunciation clips are small; cap encoded input at 10 MiB before decoding.
copyAudio :: HTTP.BodyReader -> Handle -> IO ()
copyAudio reader output = do
  bytes <- BS.concat <$> collect (10 * 1024 * 1024)
  either (ioError . userError) (BS.hPut output) (decodeAudio bytes)
  where
    collect remaining = do
      chunk <- reader
      when (BS.length chunk > remaining) $ ioError (userError "Pronunciation response exceeds 10 MiB")
      if BS.null chunk then pure [] else (chunk :) <$> collect (remaining - BS.length chunk)

-- | Save extras atomically, using the existing authenticated client and audio cache.
saveContent :: Stage
saveContent node = runExceptT $ do
  liftIO $ hPutStrLn stderr ("Lesson content: " ++ url node)
  tags <- ExceptT (extracturl (url node))
  content <- either throwE pure (parseContent (url node) tags)
  mapM_ (\file -> ExceptT (downloadWith copyAudio file {dest = dest node </> dest file})) (audioFiles content)
  root <- lift (gets download_folder)
  refresh <- lift (gets refresh_completed)
  let writeContent = if refresh then writeOutputBackup else writeOutput
  ExceptT $ liftIO $ ioEither $ writeOutput root (dest node </> "source.txt") (T.encodeUtf8 (T.pack (url node ++ "\n")))
  ExceptT $ liftIO $ ioEither $ mapM_ (\(name, value) ->
    writeContent root (dest node </> name) (T.encodeUtf8 (T.pack value)))
    [("lesson.md", markdown content), ("video-urls.txt", unlines (videoURLs content))]
  pure []

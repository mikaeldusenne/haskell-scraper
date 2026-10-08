{-# LANGUAGE OverloadedStrings #-}
-- | Episode index -> structured French dialogue and readable reference text.
module MissaBrevis where

import Control.Monad (foldM, unless, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT)
import Control.Monad.Trans.State.Strict (gets)
import Data.Aeson (encode, object, (.=))
import qualified Data.ByteString.Lazy as LB
import Data.List (nub)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Network.URI (parseURI, uriPath)
import System.FilePath ((</>), dropTrailingPathSeparator, takeFileName)
import System.IO (hPutStrLn, stderr)
import Text.HTML.TagSoup (Tag (..), canonicalizeTags, parseTags)
import Text.HTML.TagSoup.Tree (TagTree (..), tagTree, universeTree)
import Text.Printf (printf)
import Text.Read (readMaybe)
import Helpers
import Scrapper (extracturl)
import Types

config :: Config
config = defaultconfig
  { base = "https://www.missabrevis.com/codex/episodes/"
  , download_folder = "missabrevis_downloads"
  }

-- | Accept the chronological index or one episode, without following navigation.
stages :: Config -> [Stage]
stages cfg = if isEpisode (base cfg) then [saveEpisode] else [findEpisodes, saveEpisode]

isEpisode :: URLString -> Bool
isEpisode address = case fmap (filter (not . T.null) . T.splitOn "/" . T.pack . uriPath) (parseURI address) of
  Just ["codex", "episodes", _] -> True
  _ -> False

hasClass :: String -> [(String, String)] -> Bool
hasClass name attrs = maybe False (elem name . words) (lookup "class" attrs)

-- | Preserve inline punctuation; discard glossary popovers and link icons.
plain :: [TagTree String] -> String
plain = T.unpack . T.unwords . T.words . T.pack . concatMap render
  where
    render (TagLeaf (TagText value)) = value
    render (TagLeaf (TagOpen "br" _)) = "\n"
    render (TagBranch name attrs children)
      | name `elem` ["script", "style"] || any (`hasClass` attrs) ["annotation", "icone"] = ""
      | name == "br" = "\n"
      | otherwise = concatMap render children
    render _ = ""

page :: [Tag String] -> Either String [TagTree String]
page tags = case [children | TagBranch "main" attrs children <- universeTree (tagTree tags), lookup "id" attrs == Just "centre"] of
  [children] -> Right children
  _ -> Left "Expected one Missa Brevis main#centre"

-- | Retain the site's book/episode order and use numbered, URL-derived folders.
parseIndex :: URLString -> [Tag String] -> Either String [UrlWithDest]
parseIndex parent tags = do
  trees <- page tags
  rows <- case [children | TagBranch "table" attrs children <- universeTree trees, lookup "id" attrs == Just "liste_episodes"] of
    [children] -> Right [(attrs, body) | TagBranch "tr" attrs body <- universeTree children]
    _ -> Left "Expected the chronological table#liste_episodes"
  (_, reversed) <- foldM row ("", []) rows
  let episodes = reverse reversed
  when (null episodes) $ Left "No Missa Brevis episodes found"
  unless (length (nub (map url episodes)) == length episodes && length (nub (map dest episodes)) == length episodes) $
    Left "Duplicate episode URLs or destinations in the index"
  pure episodes
  where
    row (group, episodes) (attrs, children)
      | hasClass "saison" attrs = case [plain body | TagBranch "th" _ body <- children] of
          [name] | not (null name) -> Right (name, episodes)
          _ -> Left "Missing episode group heading"
      | otherwise = case [body | TagBranch "td" _ body <- children] of
          [number, title] -> do
            n <- maybe (Left "Invalid episode number") Right (readMaybe (takeWhile (/= '.') (plain number)) :: Maybe Int)
            ref <- case [value | TagBranch "a" link _ <- universeTree title, Just value <- [lookup "href" link]] of
              [value] | not (null value) -> Right value
              _ -> Left "Expected one episode link per index row"
            address <- resolveURL parent ref
            unless (n > 0 && not (null group) && isEpisode address && sameOrigin parent address) $
              Left "Invalid episode row or link outside the index origin"
            let slug = maybe "" (takeFileName . dropTrailingPathSeparator . uriPath) (parseURI address)
                folder = mkname group </> printf "%03d-%s" n (mkname slug)
            pure (group, UrlWithDest address folder : episodes)
          _ -> Left "Expected an episode number and title in each index row"

data Episode = Episode
  { episodeTitle :: String
  , episodeGroup :: String
  , episodeNumber :: Int
  , episodeLines :: [Line]
  } deriving (Eq, Show)

data Line = Line
  { sceneNumber :: Int
  , lineKind :: String
  , lineId :: Maybe String
  , speaker :: Maybe String
  , fullText :: String
  , spokenText :: String
  } deriving (Eq, Show)

-- | The site's data-contenu-ap holds speech without inline stage directions.
-- Empty speech is valid for silent actions; it must not become subtitle dialogue.
parseEpisode :: [Tag String] -> Either String Episode
parseEpisode tags = do
  trees <- page tags
  title <- case [plain body | TagBranch "h1" _ body <- trees] of
    [value] | not (null value) -> Right value
    _ -> Left "Expected one nonempty episode title"
  heading <- case [plain [child | child <- body, not (isLink child)]
                  | TagBranch "h2" attrs body <- trees, hasClass "numero_episode" attrs] of
    [value] -> Right (T.pack value)
    _ -> Left "Missing episode group and number"
  let (group, suffix) = T.breakOn " – épisode " heading
  number <- maybe (Left "Invalid episode group or number") Right
    (readMaybe (T.unpack (T.drop (T.length " – épisode ") suffix)) :: Maybe Int)
  unless (number > 0 && not (T.null group)) $ Left "Invalid episode group or number"
  let scenes = [body | TagBranch "table" attrs body <- universeTree trees, hasClass "scene" attrs]
  when (null scenes) $ Left "No scene tables found; the transcript may be unavailable"
  entries <- concat <$> traverse parseScene (zip [1..] scenes)
  when (all (null . spokenText) entries) $ Left "No spoken dialogue found in the episode"
  let ids = [ident | entry <- entries, Just ident <- [lineId entry]]
  unless (length (nub ids) == length ids) $ Left "Duplicate phrase IDs in the episode"
  pure (Episode title (T.unpack group) number entries)
  where
    isLink (TagBranch "a" _ _) = True
    isLink _ = False
    parseScene (scene, body) = do
      let rows = [(attrs, children) | TagBranch "tr" attrs children <- universeTree body]
      when (null rows) $ Left "Empty scene table"
      traverse (parseLine scene) rows
    parseLine scene (attrs, children)
      | hasClass "situation" attrs = do
          let value = plain children
          when (null value) $ Left "Empty scene description"
          pure (Line scene "situation" Nothing Nothing value "")
      | hasClass "phrase" attrs = do
          ident <- maybe (Left "Missing phrase ID") Right (lookup "id" attrs)
          when (null ident) $ Left "Empty phrase ID"
          (contentAttrs, content) <- case [(a, c) | TagBranch "td" a c <- children, hasClass "contenu" a] of
            [value] -> Right value
            _ -> Left "Expected one content cell per phrase"
          let value = plain content
          when (null value) $ Left "Empty phrase content"
          if hasClass "replique" attrs then do
            character <- case [plain c | TagBranch "td" a c <- children, hasClass "personnage" a] of
              [name] | not (null name) -> Right name
              _ -> Left "Missing speaker in dialogue row"
            speech <- maybe (Left "Missing data-contenu-ap speech attribute") Right (lookup "data-contenu-ap" contentAttrs)
            pure (Line scene "dialogue" (Just ident) (Just character) value
              (plain (tagTree (canonicalizeTags (parseTags speech)))))
          else if hasClass "didascalie" attrs then pure (Line scene "direction" (Just ident) Nothing value "")
          else Left "Unknown phrase type"
      | otherwise = Left "Unknown row in scene table"

findEpisodes :: Stage
findEpisodes node = do
  result <- extracturl (url node)
  pure (result >>= parseIndex (url node))

-- | Reuse the crawler's lock, retries, atomic writes and optional refresh backups.
saveEpisode :: Stage
saveEpisode node = runExceptT $ do
  liftIO $ hPutStrLn stderr ("Episode: " ++ url node)
  tags <- ExceptT (extracturl (url node))
  episode <- ExceptT (pure (parseEpisode tags))
  root <- lift (gets download_folder)
  refresh <- lift (gets refresh_completed)
  let entries = episodeLines episode
      metadata = object
        [ "title" .= episodeTitle episode, "group" .= episodeGroup episode
        , "episode" .= episodeNumber episode, "source" .= url node
        , "lines" .= [object
            [ "scene" .= sceneNumber entry, "kind" .= lineKind entry, "id" .= lineId entry
            , "speaker" .= speaker entry, "text" .= fullText entry, "spoken_text" .= spokenText entry
            ] | entry <- entries]
        ]
      transcript = unlines ([episodeTitle episode, episodeGroup episode ++ " – épisode " ++ show (episodeNumber episode), url node, ""]
        ++ [maybe "" (++ " : ") (speaker entry) ++ fullText entry | entry <- entries])
      dialogue = unlines [spokenText entry | entry <- entries, not (null (spokenText entry))]
      utf8 = T.encodeUtf8 . T.pack
      write = if refresh then writeOutputBackup else writeOutput
  ExceptT $ liftIO $ ioEither $ do
    writeOutput root (dest node </> "source.txt") (utf8 (url node ++ "\n"))
    mapM_ (\(name, bytes) -> write root (dest node </> name) bytes)
      [("episode.json", LB.toStrict (encode metadata) <> "\n"), ("transcript.txt", utf8 transcript), ("dialogue.txt", utf8 dialogue)]
  pure []

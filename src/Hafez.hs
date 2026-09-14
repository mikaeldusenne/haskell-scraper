-- | The Hafez adapter: group index -> ghazal index -> bilingual text.
module Hafez where

import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT)
import Control.Monad.Trans.State.Strict (gets)
import Data.List (nub)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import System.FilePath ((</>))
import Text.HTML.TagSoup
import Text.HTML.TagSoup.Tree (TagTree (..), tagTree, universeTree)
import Helpers
import Scrapper
import Types

-- | Pure selectors for the current group/ghazal lists. Reject layout changes.
extractLinks :: URLString -> [Tag String] -> Either String [UrlWithDest]
extractLinks parent tags = do
  let refs = nub (concat [tag_class_f "a" cls (fromAttrib "href") tags | cls <- ["group-card", "g-link"]])
  when (null refs || any null refs) $ Left "No Hafez links found (expected group-card or g-link anchors)"
  traverse (\ref -> do
    address <- resolveURL parent ref
    pure (UrlWithDest address (url_basename address))) refs

-- | Fetch an index and return the links selected by 'extractLinks'.
findlinks :: Stage
findlinks node = do
  result <- extracturl (url node)
  pure (result >>= extractLinks (url node))

-- | Preserve inline markup text and line breaks; require aligned English/Farsi
-- verse blocks so a changed layout cannot silently generate empty/truncated files.
parsePoem :: [Tag String] -> Either String (String, String)
parsePoem tags = do
  let blocks cls = [T.strip (T.pack (concatMap render children))
                  | TagBranch "div" attrs children <- universeTree (tagTree tags)
                  , cls `elem` words (maybe "" id (lookup "class" attrs))]
      english = blocks "v-en"
      farsi = blocks "v-fa"
      combine = T.unpack . (<> T.pack "\n") . T.intercalate (T.pack "\n\n")
  when (null english || length english /= length farsi || any T.null (english ++ farsi)) $
    Left "Expected matching, nonempty v-en and v-fa verse blocks"
  pure (combine english, combine farsi)
  where
    render (TagLeaf (TagText text)) = text
    render (TagLeaf (TagOpen "br" _)) = "\n"
    render (TagBranch "br" _ _) = "\n"
    render (TagBranch _ _ children) = concatMap render children
    render _ = ""

-- | Save English, Farsi and source URL as UTF-8 files; preserve existing content.
genPoem :: Stage
genPoem node = runExceptT $ do
  tags <- ExceptT (extracturl (url node))
  (english, farsi) <- ExceptT (pure (parsePoem tags))
  root <- lift (gets download_folder)
  ExceptT $ liftIO $ ioEither $ mapM_ (\(name, content) ->
    writeOutput root (dest node </> name) (T.encodeUtf8 (T.pack content)))
    [("en.txt", english), ("fa.txt", farsi), ("source.txt", url node ++ "\n")]
  pure []

-- | Initialize the Hafez output directory with the default HTTPS source.
mkcfg :: IO Config
mkcfg = createConfig defaultconfig
  { download_folder = "hafez_downloads"
  , base = "https://www.hafizonlove.com/divan/"
  }

-- | Group index, ghazal index, then bilingual text extraction.
fs :: [Stage]
fs = [findlinks, findlinks, genPoem]

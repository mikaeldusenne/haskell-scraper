-- Download one page's group-card links from the local demonstration site.
module Main (main) where

import Control.Monad (unless, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT)
import Helpers (resolveURL, url_basename)
import Scrapper (download, extracturl, mainLoop, tag_class_f)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import Text.HTML.TagSoup (fromAttrib)
import Types

saveLinks :: Stage
saveLinks node = runExceptT $ do
  tags <- ExceptT (extracturl (url node))
  addresses <- ExceptT $ pure $ traverse (resolveURL (url node))
    (tag_class_f "a" "group-card" (fromAttrib "href") tags)
  when (null addresses) $ ExceptT (pure (Left "No group-card links found"))
  mapM_ (\address -> ExceptT (download (UrlWithDest address (dest node </> url_basename address)))) addresses
  liftIO (putStrLn "Saved linked HTML pages.")
  pure []

main :: IO ()
main = do
  ok <- mainLoop defaultconfig
    {base = "http://127.0.0.1:8000/", download_folder = "example_downloads"}
    [saveLinks]
  unless ok exitFailure

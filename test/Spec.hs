{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Monad (unless, void)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.State.Strict (evalStateT, gets)
import qualified Data.ByteString as BS
import Data.Either (isLeft)
import Data.IORef
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Hafez (extractLinks, parsePoem)
import Helpers
import Network.HTTP.Client (brConsume)
import Scrapper
import System.Directory
import System.Environment (lookupEnv)
import System.FilePath
import System.IO.Error (tryIOError)
import System.IO.Temp (withSystemTempDirectory)
import Text.HTML.TagSoup
import Types

assert :: String -> Bool -> IO ()
assert label ok = unless ok (ioError (userError label))

main :: IO ()
main = do
  assert "URL references" $ and
    [ resolveURL "https://example.org/a/index.html" "../b?q=1#x" == Right "https://example.org/b?q=1"
    , resolveURL "https://example.org/a/" "/b" == Right "https://example.org/b"
    , resolveURL "https://example.org/a/" "//cdn.example.org/b" == Right "https://cdn.example.org/b"
    , isLeft (resolveURL "https://example.org/" "file:///etc/passwd")
    , isLeft (resolveURL "https://example.org/" "https://user:password@example.org/")
    , url_basename "https://example.org/" == "index.html"
    , url_basename "/file?id=1" /= url_basename "/file?id=2"
    ]
  assert "Destination traversal rejected" $ all (isLeft . prepareChildren (UrlWithDest "https://example.org/" "/tmp/output") . pure . UrlWithDest "a")
    ["../escape", "/absolute", ".", ".scraper-lock"]
  assert "Equivalent child references are deduplicated" $
    fmap length (prepareChildren (UrlWithDest "https://example.org/" "/tmp/output")
      [UrlWithDest "a" "a", UrlWithDest "./a#section" "./a"]) == Right 1
  assert "Malformed cache rejected" (isLeft (readCache "not a tuple"))
  tags <- canonicalizeTags . parseTags . T.unpack <$> T.readFile "test/fixtures/p_demo.html"
  assert "Bilingual text and inline markup" $ parsePoem tags == Right
    ("Hello world.\nOne & two.\n\nAnother line.\n", "سلام دنیا\nیک و دو\n\nیک خط دیگر\n")
  assert "Missing language rejected" $ isLeft (parsePoem (parseTags "<div class='v-en'>Only English</div>"))
  assert "Layout changes rejected" $ isLeft (extractLinks "https://example.org/" (parseTags "<a href='x'>Navigation</a>"))
  withSystemTempDirectory "scraper-test" $ \directory -> do
    cfg <- createConfig defaultconfig {download_folder = directory, retry_count = 0, retry_delay_ms = 0}
    attempts <- newIORef (0 :: Int)
    result <- evalStateT (retry 2 "failure" (liftIO (modifyIORef' attempts (+1)) >> pure (Left "failed" :: Either String ()))) cfg
    count <- readIORef attempts
    assert "Retry budget" (isLeft result && count == 3)
    let path = directory </> "keep.txt"
    writeOutput directory path "original"
    refused <- tryIOError (writeOutput directory path "different")
    bytes <- BS.readFile path
    assert "Existing content preserved" (isLeft refused && bytes == "original")
    failedWrite <- tryIOError (atomicWrite (directory </> "partial") (\_ -> ioError (userError "interrupted")))
    files <- listDirectory directory
    assert "Failed writes leave no partial files" (isLeft failedWrite && files == ["keep.txt"])
    createDirectoryLink ".." (directory </> "escape")
    escape <- tryIOError (checkOutput directory (directory </> "escape" </> "outside"))
    assert "Symlink escape rejected" (isLeft escape)
  testResume
  lookupEnv "SCRAPER_TEST_ORIGIN" >>= maybe (pure ()) testHTTP
  putStrLn "All regression checks passed."

testResume :: IO ()
testResume = withSystemTempDirectory "scraper-resume" $ \directory -> do
  seen <- newIORef ([] :: [String])
  failSecond <- newIORef True
  let cfg = defaultconfig {download_folder = directory, retry_count = 0}
      children _ = pure (Right [UrlWithDest "a" "a", UrlWithDest "b" "b"])
      leaf node = do
        failing <- liftIO (readIORef failSecond)
        liftIO (modifyIORef' seen (++ [takeFileName (dest node)]))
        pure $ if failing && takeFileName (dest node) == "b" then Left "simulated failure" else Right []
  firstRun <- mainLoop cfg [children, leaf]
  marked <- doesFileExist (directory </> ".scraper-finished")
  assert "Failed descendants do not finish the parent" (not firstRun && not marked)
  writeIORef failSecond False
  secondRun <- mainLoop cfg [children, leaf]
  visits <- readIORef seen
  assert "Resume skips successful siblings" (secondRun && visits == ["a", "b", "b"])

-- Run only against the loopback server started by smoke.py, never a public site.
testHTTP :: String -> IO ()
testHTTP origin = withSystemTempDirectory "scraper-http" $ \directory -> do
  cfg <- createConfig defaultconfig {download_folder = directory, base = origin, request_delay_ms = 0, timeout_seconds = 1}
  let run action = evalStateT action cfg
  missing <- run (openURL "missing")
  assert "HTTP 404 is an error" (isLeft missing)
  redirect <- run (openURL "external")
  assert "Cross-origin redirect is refused" (isLeft redirect)
  slow <- run (openURL "slow")
  assert "HTTP response timeout" (isLeft slow)
  failed <- run $ do
    result <- download (UrlWithDest "broken" (directory </> "broken.bin"))
    cache <- gets alreadies_urls
    pure (result, cache)
  assert "Failed download not cached" (isLeft (fst failed) && null (snd failed))
  exists <- doesPathExist (directory </> "broken.bin")
  assert "Failed transfer not installed" (not exists)
  completed <- run $ do
    a <- download (UrlWithDest "asset" (directory </> "a.bin"))
    b <- download (UrlWithDest "asset" (directory </> "b.bin"))
    pure (a, b)
  a <- BS.readFile (directory </> "a.bin")
  b <- BS.readFile (directory </> "b.bin")
  assert "Cached download copied completely" (completed == (Right (), Right ()) && a == b && BS.length a == 100000)
  loggedIn <- run $ do
    submitted <- request "login" (Just [("name", "test+&=é"), ("password", "p&=+ss")]) (void . brConsume)
    page <- openURL "protected"
    pure (submitted, page)
  assert "Encoded login and cookie session" (loggedIn == (Right (), Right "authenticated"))

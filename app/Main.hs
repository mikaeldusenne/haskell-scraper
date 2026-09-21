module Main (main) where

import Control.Monad (foldM, unless)
import qualified AmeriLingua
import qualified AmeriLinguaContent
import qualified AmeriLinguaIndex
import Data.Version (showVersion)
import Hafez (fs)
import Paths_haskellwebscrapper (version)
import Scrapper (mainLoop)
import System.Console.GetOpt
import System.Environment (getArgs)
import System.Exit (die, exitFailure)
import Text.Read (readMaybe)
import Types

type Option = Config -> Either String Config

options :: [OptDescr Option]
options =
  [ Option ['o'] ["output"] (ReqArg (\value cfg -> Right cfg {download_folder = value}) "DIR") "Output directory (default: <site>_downloads)"
  , Option [] ["base-url"] (ReqArg (\value cfg -> Right cfg {base = value}) "URL") "Starting URL (site default; AmeriLingua also accepts one lesson)"
  , Option [] ["delay-ms"] (ReqArg (number (\n cfg -> cfg {request_delay_ms = n})) "N") "Delay before each request (default: 1000)"
  , Option [] ["retries"] (ReqArg (number (\n cfg -> cfg {retry_count = n})) "N") "Extra attempts per failed stage (default: 2)"
  , Option [] ["timeout-seconds"] (ReqArg (number (\n cfg -> cfg {timeout_seconds = n})) "N") "HTTP response timeout (default: 30; must be positive)"
  , Option [] ["refresh"] (NoArg (\cfg -> Right cfg {refresh_completed = True})) "Revisit completed nodes; content text is backed up before updates"
  ]
  where
    number set value cfg = case readMaybe value of
      Just n | n >= 0 -> Right (set n cfg)
      _ -> Left ("Expected a nonnegative integer, got: " ++ value)

usage :: String
usage = usageInfo "Usage: haskellwebscrapper-exe (hafez|amerilingua|amerilingua-content|amerilingua-index) [OPTIONS]\n       haskellwebscrapper-exe --help | --version\n\nhafez: English/Farsi poems. amerilingua: lesson PDFs and resource links.\namerilingua-content: objectives, transcript, vocabulary, audio and video URLs.\namerilingua-index: metadata, ordered sequences and tag navigation.\nAmeriLingua login: AMERILINGUA_LOGIN/PASS (see docs/AMERILINGUA.md).\nNo arguments prints help without crawling.\n" options

run :: Config -> (Config -> [Stage]) -> [String] -> IO ()
run _ _ ["--help"] = putStrLn usage
run _ _ ["-h"] = putStrLn usage
run defaults pipeline args = do
  let (updates, unexpected, errors) = getOpt Permute options args
  unless (null errors && null unexpected) $ die (concat errors ++ "Unexpected arguments: " ++ unwords unexpected ++ "\n" ++ usage)
  cfg <- either die pure $ foldM (flip ($)) defaults updates
  ok <- mainLoop cfg (pipeline cfg)
  unless ok exitFailure

main :: IO ()
main = do
  args <- getArgs
  case args of
    [] -> putStrLn usage
    ["--help"] -> putStrLn usage
    ["-h"] -> putStrLn usage
    ["--version"] -> putStrLn (showVersion version)
    "hafez" : rest -> run defaultconfig
      {download_folder = "hafez_downloads", base = "https://www.hafizonlove.com/divan/"}
      (const fs) rest
    "amerilingua" : rest -> run AmeriLingua.config AmeriLingua.stages rest
    "amerilingua-content" : rest -> run AmeriLinguaContent.config AmeriLinguaContent.stages rest
    "amerilingua-index" : rest -> run AmeriLinguaIndex.config AmeriLinguaIndex.stages rest
    _ -> die usage

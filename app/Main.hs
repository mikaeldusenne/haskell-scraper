module Main (main) where

import Control.Monad (foldM, unless)
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
  [ Option ['o'] ["output"] (ReqArg (\value cfg -> Right cfg {download_folder = value}) "DIR") "Output directory (default: hafez_downloads)"
  , Option [] ["base-url"] (ReqArg (\value cfg -> Right cfg {base = value}) "URL") "Index URL (default: https://www.hafizonlove.com/divan/)"
  , Option [] ["delay-ms"] (ReqArg (number (\n cfg -> cfg {request_delay_ms = n})) "N") "Delay before each request (default: 1000)"
  , Option [] ["retries"] (ReqArg (number (\n cfg -> cfg {retry_count = n})) "N") "Extra attempts per failed stage (default: 2)"
  , Option [] ["timeout-seconds"] (ReqArg (number (\n cfg -> cfg {timeout_seconds = n})) "N") "HTTP response timeout (default: 30; must be positive)"
  ]
  where
    number set value cfg = case readMaybe value of
      Just n | n >= 0 -> Right (set n cfg)
      _ -> Left ("Expected a nonnegative integer, got: " ++ value)

usage :: String
usage = usageInfo "Usage: haskellwebscrapper-exe hafez [OPTIONS]\n       haskellwebscrapper-exe --help | --version\n\nExtract English and Farsi ghazals from Hafez-style pages.\nNo arguments prints help without crawling.\n" options

main :: IO ()
main = do
  args <- getArgs
  case args of
    [] -> putStrLn usage
    ["--help"] -> putStrLn usage
    ["-h"] -> putStrLn usage
    ["--version"] -> putStrLn (showVersion version)
    ["hafez", "--help"] -> putStrLn usage
    "hafez" : rest -> do
      let (updates, unexpected, errors) = getOpt Permute options rest
      unless (null errors && null unexpected) $ die (concat errors ++ "Unexpected arguments: " ++ unwords unexpected ++ "\n" ++ usage)
      cfg <- either die pure $ foldM (flip ($)) defaultconfig
        {download_folder = "hafez_downloads", base = "https://www.hafizonlove.com/divan/"} updates
      ok <- mainLoop cfg fs
      unless ok exitFailure
    _ -> die usage

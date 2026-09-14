-- | Configuration and the state shared by all stages of one crawl.
module Types where

import Control.Monad (unless, when)
import Control.Monad.Trans.State.Strict (StateT, gets)
import qualified Data.Text.IO as T
import qualified Data.Text as T
import Network.HTTP.Client (CookieJar, createCookieJar)
import System.Directory
import System.FilePath
import Text.HTML.TagSoup (Tag (..))
import Text.Read (readMaybe)

type URLString = String
type Path = FilePath
type Cache = [(URLString, Path)]
type PPM a = StateT Config IO a
type ErrorDetails = Either (String, String) ()
-- | Return child URLs and paths relative to this node; a leaf returns @Right []@.
type Stage = UrlWithDest -> PPM (Either String [UrlWithDest])

data UrlWithDest = UrlWithDest {url :: URLString, dest :: FilePath}
  deriving (Eq, Show)

defaultUrlWithDest :: UrlWithDest
defaultUrlWithDest = UrlWithDest "" ""

data Config = Config
  { download_folder :: Path
  , base :: URLString
  , login_path :: Maybe String
  , login_arg_login :: String
  , login_arg_pass :: String
  , login_env_prefix :: String
  , login_needed_tag :: Tag String
  , urlsfile :: Path
  , alreadies_urls :: Cache
  , request_delay_ms :: Int
  , retry_count :: Int
  , retry_delay_ms :: Int
  , timeout_seconds :: Int
  , session_cookies :: CookieJar
  }

-- | Delays apply to every HTTP request, including redirects and login.
defaultconfig :: Config
defaultconfig = Config
  { download_folder = "scrapper_downloads"
  , base = "https://example.com/"
  , login_path = Nothing
  , login_arg_login = "member_login"
  , login_arg_pass = "member_pass"
  , login_env_prefix = "SCRAPER_"
  , login_needed_tag = TagOpen "button" [("aria-label", "Please sign in")]
  , urlsfile = ".scraper-urls"
  , alreadies_urls = []
  , request_delay_ms = 1000
  , retry_count = 2
  , retry_delay_ms = 2000
  , timeout_seconds = 30
  , session_cookies = createCookieJar []
  }

-- | Validate local settings and create the output directory. Cache loading happens
-- under the crawl lock in 'Scrapper.mainLoop'. No credentials are read here.
createConfig :: Config -> IO Config
createConfig cfg = do
  unless (all (>= 0) [request_delay_ms cfg, retry_delay_ms cfg, retry_count cfg]
          && timeout_seconds cfg > 0) $
    ioError (userError "Delays/retries must be nonnegative; timeout must be positive")
  when (null (download_folder cfg)) $ ioError (userError "Output directory is empty")
  unless (takeFileName (urlsfile cfg) == urlsfile cfg
          && urlsfile cfg `notElem` ["", ".", "..", ".scraper-lock", ".scraper-source", ".scraper-finished"]) $
    ioError (userError "urlsfile must be a plain filename, distinct from crawler metadata")
  createDirectoryIfMissing True (download_folder cfg)
  root <- canonicalizePath (download_folder cfg)
  pure cfg {download_folder = root}

-- | Reject damaged cache records with a line number instead of a partial 'read'.
readCache :: String -> Either String Cache
readCache = traverse parse . zip [1 :: Int ..] . lines
  where
    parse (n, line) = maybe (Left ("Invalid cache record at line " ++ show n)) Right (readMaybe line)

loadCache :: Config -> IO Config
loadCache cfg = do
  let path = download_folder cfg </> urlsfile cfg
  exists <- doesFileExist path
  records <- if exists then T.unpack <$> T.readFile path else pure ""
  cache <- either (ioError . userError) pure (readCache records)
  pure cfg {alreadies_urls = cache}

handle_url_cache :: URLString -> PPM (Maybe Path)
handle_url_cache target = gets (lookup target . alreadies_urls)

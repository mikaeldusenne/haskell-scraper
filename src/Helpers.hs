{-# LANGUAGE OverloadedStrings #-}
-- | URL resolution, checked HTTP requests and safe local writes.
module Helpers where

import Control.Concurrent (threadDelay)
import Control.Exception (try)
import Control.Monad (unless, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.State.Strict (get, gets, modify')
import Data.Bifunctor (first)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LB
import Data.Char (isAlphaNum, isSpace, toLower)
import Data.Digest.Pure.SHA (sha256, showDigest)
import Data.List (dropWhileEnd)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Network.HTTP.Client as HTTP
import Network.HTTP.Client.TLS (getGlobalManager)
import Network.HTTP.Types.Status (statusCode)
import Network.URI (URI (..), URIAuth (..), parseURI, parseURIReference, relativeTo)
import System.Directory
import System.FilePath
import System.IO (Handle, hClose, hSetBinaryMode)
import System.IO.Error (catchIOError, isDoesNotExistError, tryIOError)
import System.IO.Temp (withTempFile)
import Types

-- | A bounded filename component, preserving letters, digits, dots and dashes.
mkname :: String -> String
mkname input = case map clean (dropWhileEnd isSpace (dropWhile isSpace input)) of
  "" -> "index.html"
  "." -> "index.html"
  ".." -> "index.html"
  name -> take 180 name
  where clean c = if isAlphaNum c || c `elem` ("._-" :: String) then c else '_'

-- | Resolve RFC 3986 references and discard fragments (never sent to the server).
resolveURL :: URLString -> URLString -> Either String URLString
resolveURL parent reference = do
  origin <- maybe (Left "Invalid base URL") Right (parseURI parent)
  relative <- maybe (Left "Invalid URL reference") Right (parseURIReference reference)
  let resolved = relative `relativeTo` origin
  case uriAuthority resolved of
    Just authority | map toLower (uriScheme resolved) `elem` ["http:", "https:"]
                     && not (null (uriRegName authority)) && null (uriUserInfo authority) ->
      Right (show resolved {uriFragment = ""})
    _ -> Left "Only absolute HTTP(S) URLs without embedded credentials are supported"

-- | Compare scheme, hostname and effective port (including default ports).
sameOrigin :: String -> String -> Bool
sameOrigin a b = case (parseURI a >>= origin, parseURI b >>= origin) of
  (Just x, Just y) -> x == y
  _ -> False
  where
    origin uri = do
      auth <- uriAuthority uri
      let scheme = map toLower (uriScheme uri)
          port = if null (uriPort auth) then if scheme == "https:" then ":443" else ":80" else uriPort auth
      pure (scheme, map toLower (uriRegName auth), port)

-- | Resolve against the configured base; use 'resolveURL' for nested pages.
mkurl :: URLString -> PPM (Either String URLString)
mkurl reference = gets (\cfg -> resolveURL (base cfg) reference)

-- | Queries identify distinct resources; a digest avoids filename collisions.
url_basename :: String -> FilePath
url_basename input = case parseURIReference input of
  Nothing -> mkname input
  Just uri -> mkname (takeFileName (uriPath uri)) ++ suffix (uriQuery uri)
  where suffix "" = ""
        suffix query = "-" ++ take 16 (showDigest (sha256 (LB.fromStrict (T.encodeUtf8 (T.pack query)))))

-- | Paths supplied by extraction stages must remain below their parent.
safeRelative :: FilePath -> Bool
safeRelative path = not (null path || isAbsolute path) && all valid (splitDirectories path)
  where valid part = part /= ".." && not (any (`elem` ("\\\0" :: String)) part)

-- | Catch expected filesystem errors without swallowing Ctrl-C or programming errors.
ioEither :: IO a -> IO (Either String a)
ioEither action = first show <$> tryIOError action

-- | Check canonical containment, including pre-existing symlinks in ancestors.
checkOutput :: FilePath -> FilePath -> IO ()
checkOutput root path = do
  canonical <- canonicalizePath path
  unless (canonical == root || safeRelative (makeRelative root canonical)) $
    ioError (userError ("Output escapes download directory: " ++ path))
  symbolic <- pathIsSymbolicLink path `catchIOError` \e ->
    if isDoesNotExistError e then pure False else ioError e
  when symbolic $ ioError (userError ("Refusing symbolic link: " ++ path))

-- | Stage data beside the destination so a failed transfer leaves no partial file.
atomicWrite :: FilePath -> (Handle -> IO ()) -> IO ()
atomicWrite path write = withTempFile (takeDirectory path) ".scraper-tmp" $ \tmp handle -> do
  hSetBinaryMode handle True
  write handle
  hClose handle
  renameFile tmp path

-- | Preserve existing user data; identical generated output is safe to resume.
writeOutput :: FilePath -> FilePath -> BS.ByteString -> IO ()
writeOutput root path bytes = do
  checkOutput root path
  exists <- doesPathExist path
  if exists
    then do
      previous <- BS.readFile path
      unless (previous == bytes) $ ioError (userError ("Refusing to overwrite different content: " ++ path))
    else atomicWrite path (`BS.hPut` bytes)

-- | Millisecond delay with checked conversion to the runtime's microseconds.
pause :: Int -> IO ()
pause ms = threadDelay (fromInteger (min (toInteger (maxBound :: Int)) (1000 * toInteger ms)))

-- | One request chain, with bounded redirects, same-origin cookies and status checks.
-- The consumer streams downloads; page callers may collect the body in memory.
request :: URLString -> Maybe [(String, String)] -> (HTTP.BodyReader -> IO a) -> PPM (Either String a)
request target form consume = do
  resolved <- mkurl target
  either (pure . Left) (go (10 :: Int) form) resolved
  where
    go remaining fields address = do
      cfg <- get
      if not (sameOrigin (base cfg) address)
        then pure (Left "Refusing a request outside the configured origin")
        else do
          result <- liftIO $ ioEither $ do
            pause (request_delay_ms cfg)
            response <- try $ do
              manager <- getGlobalManager
              initial <- HTTP.parseRequest address
              let encode = T.encodeUtf8 . T.pack
                  formRequest = maybe initial (\pairs -> HTTP.urlEncodedBody [(encode k, encode v) | (k, v) <- pairs] initial) fields
                  req = formRequest
                    { HTTP.cookieJar = Just (session_cookies cfg)
                    , HTTP.redirectCount = 0
                    , HTTP.checkResponse = \_ _ -> pure ()
                    , HTTP.responseTimeout = HTTP.responseTimeoutMicro (fromInteger (min (toInteger (maxBound :: Int)) (1000000 * toInteger (timeout_seconds cfg))))
                    , HTTP.requestHeaders = [("User-Agent", "haskell-scraper/0.2")]
                        ++ HTTP.requestHeaders formRequest
                    }
              HTTP.withResponse req manager $ \res -> do
                body <- if statusCode (HTTP.responseStatus res) `div` 100 == 2
                        then Just <$> consume (HTTP.responseBody res) else pure Nothing
                pure (body <$ res)
            pure (first httpError response)
          case result >>= id of
            Left err -> pure (Left err)
            Right response -> do
              modify' (\state -> state {session_cookies = HTTP.responseCookieJar response})
              let code = statusCode (HTTP.responseStatus response)
              case HTTP.responseBody response of
                Just value -> pure (Right value)
                Nothing | code `elem` [301, 302, 303, 307, 308], remaining > 0 ->
                  case lookup "Location" (HTTP.responseHeaders response) of
                    Nothing -> pure (Left "Redirect has no Location header")
                    Just location -> case T.decodeUtf8' location of
                      Left _ -> pure (Left "Invalid redirect encoding")
                      Right ref -> either (pure . Left) (go (remaining - 1) (if code `elem` [301, 302, 303] then Nothing else fields))
                        (resolveURL address (T.unpack ref))
                Nothing -> pure (Left ("HTTP status " ++ show code ++ if remaining == 0 then " (redirect limit reached)" else ""))
    -- Do not render requests: they can contain credentials and session cookies.
    httpError :: HTTP.HttpException -> String
    httpError (HTTP.InvalidUrlException _ _) = "Invalid HTTP URL"
    httpError (HTTP.HttpExceptionRequest _ HTTP.ResponseTimeout) = "HTTP response timeout"
    httpError (HTTP.HttpExceptionRequest _ HTTP.ConnectionTimeout) = "HTTP connection timeout"
    httpError _ = "HTTP transport failure (connection, TLS or incomplete response)"

-- | UTF-8 HTML. Cookies are held in @Config@, never written to disk.
openURL :: URLString -> PPM (Either String String)
openURL target = do
  bytes <- request target Nothing (fmap BS.concat . HTTP.brConsume)
  pure $ bytes >>= first (const "Page is not valid UTF-8") . fmap T.unpack . T.decodeUtf8'

-- | Context and the last error from an exhausted retry budget.
type NamedErrorStr = (String, String)

-- | At most @1 + retries@ attempts; no delay after the final failure.
retry :: Int -> String -> PPM (Either String a) -> PPM (Either NamedErrorStr a)
retry retries description action = do
  result <- action
  case result of
    Left _ | retries > 0 -> do
      gets retry_delay_ms >>= liftIO . pause
      retry (retries - 1) description action
    _ -> pure (first ((,) description) result)

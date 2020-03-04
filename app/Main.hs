{-# LANGUAGE GeneralisedNewtypeDeriving #-}
{-# LANGUAGE TupleSections              #-}


module Main where

import           Control.Concurrent.Async      (mapConcurrently)
import           Control.Concurrent.QSem       (newQSem, signalQSem, waitQSem)
import           Control.Exception             (bracket_)
import           Control.Lens                  hiding (argument)
import           Control.Monad                 (when)
import           Control.Monad.IO.Class        (MonadIO (..))
import           Control.Monad.Logger          (LogLevel (..), LoggingT,
                                                MonadLogger, filterLogger,
                                                logDebugN, logInfoN,
                                                runStderrLoggingT)
import           Control.Monad.Reader          (MonadReader, ReaderT (..), ask,
                                                asks, lift, runReaderT)
import           Data.List.Extra               (chunksOf)
import qualified Data.Set                      as Set
import qualified Data.Text                     as T
import qualified Data.Text.Lazy                as LT
import           GoPro
import           GoPro.AuthDB
import           GoPro.DB
import           Network.Wai.Middleware.Static (addBase, noDots, staticPolicy,
                                                (>->))
import           Options.Applicative           (Parser, argument, execParser,
                                                fullDesc, help, helper, info,
                                                long, metavar, progDesc, short,
                                                showDefault, some, str,
                                                strOption, switch, value,
                                                (<**>))
import           System.FilePath.Posix         ((</>))
import           System.IO                     (hFlush, hGetEcho, hSetEcho,
                                                stdin, stdout)
import           Web.Scotty.Trans              (ScottyT, file, get, json,
                                                middleware, param, raw, scottyT,
                                                setHeader)

data Options = Options {
  optDBPath     :: String,
  optStaticPath :: FilePath,
  optVerbose    :: Bool,
  optArgv       :: [String]
  }

data Env = Env {
  gpOptions :: Options,
  gpToken   :: String
  }

newtype EnvM a = EnvM
  { runEnvM :: ReaderT Env IO a
  } deriving (Applicative, Functor, Monad, MonadIO, MonadReader Env)

type GoPro = ReaderT Env (LoggingT IO)

options :: Parser Options
options = Options
  <$> strOption (long "dbpath" <> showDefault <> value "gopro.db" <> help "db path")
  <*> strOption (long "static" <> showDefault <> value "static" <> help "static asset path")
  <*> switch (short 'v' <> long "verbose" <> help "enable debug logging")
  <*> some (argument str (metavar "cmd args..."))

logInfo :: MonadLogger m => T.Text -> m ()
logInfo = logInfoN

logDbg :: MonadLogger m => T.Text -> m ()
logDbg = logDebugN

tshow :: Show a => a -> T.Text
tshow = T.pack . show

mapConcurrentlyLimited :: (Traversable f, Foldable f) => Int -> (a -> IO b) -> f a -> IO (f b)
mapConcurrentlyLimited n f l = newQSem n >>= \q -> mapConcurrently (b q) l
  where b q x = bracket_ (waitQSem q) (signalQSem q) (f x)

data SyncType = Full | Incremental

runSync :: SyncType -> GoPro ()
runSync stype = do
  tok <- asks gpToken
  db <- asks (optDBPath . gpOptions)
  seen <- Set.fromList <$> loadMediaIDs db
  ms <- todo tok seen
  logInfo $ tshow (length ms) <> " new items"
  when (not . null $ ms) $ logDbg $ "new items: " <> tshow (ms ^.. folded . media_id)
  mapM_ (storeSome tok db) $ chunksOf 100 ms

    where resolve tok m = MediaRow m <$> fetchThumbnail tok m
          todo tok seen = filter (\m@Media{..} -> notSeen m && _media_ready_to_view == "ready")
                          <$> listWhile tok (listPred stype)
            where
              notSeen = (`Set.notMember` seen) . _media_id
              listPred Incremental = all notSeen
              listPred Full        = const True
          storeSome tok db l = do
            logInfo $ "Storing batch of " <> tshow (length l)
            storeMedia db =<< fetch tok l
          fetch tok = liftIO . mapConcurrentlyLimited 11 (resolve tok)

runAuth :: GoPro ()
runAuth = do
  liftIO (prompt "Enter email: ")
  u <- liftIO getLine
  p <- liftIO getPass
  db <- asks (optDBPath . gpOptions)
  res <- authenticate u p
  updateAuth db res

  where
    prompt x = putStr x >> hFlush stdout
    withEcho echo action = do
      prompt "Enter password: "
      old <- hGetEcho stdin
      bracket_ (hSetEcho stdin echo) (hSetEcho stdin old) action

    getPass = withEcho False getLine

runReauth :: GoPro ()
runReauth = do
  db <- asks (optDBPath . gpOptions)
  a <- loadAuth db
  res <- refreshAuth a
  updateAuth db res

runServer :: GoPro ()
runServer = ask >>= \x -> scottyT 8008 (runIO x) application
  where
    runIO :: Env -> EnvM a -> IO a
    runIO e m = runReaderT (runEnvM m) e

    application :: ScottyT LT.Text EnvM ()
    application = do
      let staticPath = "static"
      middleware $ staticPolicy (noDots >-> addBase staticPath)

      get "/" $ do
        setHeader "Content-Type" "text/html"
        file $ staticPath </> "index.html"

      get "/api/media" $ do
        db <- lift $ asks (optDBPath . gpOptions)
        meds <- loadMedia db
        json meds

      get "/thumb/:id" $ do
        db <- lift $ asks (optDBPath . gpOptions)
        imgid <- param "id"
        imgdata <- loadThumbnail db imgid
        setHeader "Content-Type" "image/jpeg"
        raw imgdata

run :: String -> GoPro ()
run "auth"     = runAuth
run "reauth"   = runReauth
run "sync"     = runSync Incremental
run "fullsync" = runSync Full
run "serve"    = runServer
run x          = fail ("unknown command: " <> x)

main :: IO ()
main = do
  o@Options{..} <- execParser opts
  tok <- loadToken optDBPath
  runStderrLoggingT . logfilt o $ runReaderT (run (head optArgv)) (Env o tok)

  where
    opts = info (options <**> helper)
           ( fullDesc <> progDesc "GoPro cloud utility.")
    logfilt Options{..} = filterLogger (\_ -> flip (if optVerbose then (>=) else (>)) LevelDebug)

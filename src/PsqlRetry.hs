{-# language ApplicativeDo #-}
{-# language BlockArguments #-}
{-# language DerivingStrategies #-}
{-# language FlexibleContexts #-}
{-# language ImportQualifiedPost #-}
{-# language NumericUnderscores #-}
{-# language OverloadedRecordDot #-}
{-# language QuasiQuotes #-}
{-# language ScopedTypeVariables #-}

module PsqlRetry (runMain, PsqlStatus(..), PsqlRetry(..), retryPsql) where

import Control.Concurrent (throwTo, myThreadId, threadDelay)
import Control.Exception (AsyncException (..), SomeException, catch, throwIO)
import Control.Monad (when)
import Control.Retry qualified as Retry
import Data.Function ((&))
import Data.IORef
import Data.String.Interpolate (iii)
import Data.Text.IO qualified as T
import Data.Word
import OptEnvConf
import Paths_psql_retry (version)
import Streamly.Console.Stdio qualified as Stream.Console.Stdio
import Streamly.Data.Array qualified as Array
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream
import Streamly.Internal.Data.Stream qualified as StreamD
import Streamly.System.Process qualified as Process
import Streamly.Unicode.Stream qualified as Unicode
import System.Exit (exitFailure, exitSuccess)
import System.Mem (performMinorGC)
import System.Posix.Signals


runMain :: IO ()
runMain = do
    -- don't use the one from safe-exceptions/rio/unlift-io, as it doesn't
    -- catch AsyncException
    Control.Exception.catch
        runMain2
        \(e :: SomeException) -> do
            performMinorGC
            -- \^ run any pending finalisers
            threadDelay 3_000_000
            -- \^ hopefully that's enough for psql
            throwIO e


runMain2 :: IO ()
runMain2 = do
    tId <- myThreadId

    installHandler sigTERM (CatchOnce (throwTo tId UserInterrupt)) Nothing

    PsqlRetry args <- runSettingsParser version description
    retryPsql args
  where
    description :: String
    description = "Retry psql on lock timeout errors, instead of doing the same from inside a plpgsql script as that can cause further issues due to the presence of subtransactions"


data PsqlRetry = PsqlRetry String

instance HasParser PsqlRetry where
  settingsParser = do
    psqlArgs <- setting [ help "The exact string to be passed to psql command"
                        , reader str
                        , OptEnvConf.env "PSQL_ARGS"
                        , metavar "PSQL_ARGS"
                        , argument
                        ]
    pure $ PsqlRetry psqlArgs

data PsqlStatus = ShouldRetry | PsqlSuccess | ShouldExit
    deriving stock (Show)


retryPsql :: String -> IO ()
retryPsql args = do
    exhausted <-
        Retry.retrying
            ( Retry.capDelay 60_000_000 do
                Retry.fullJitterBackoff 10_000 <> Retry.limitRetries numRetries
            )
            shouldRetry
            psql

    case exhausted of
        PsqlSuccess -> exitSuccess
        a -> do
            putStrLn (show a)
            exitFailure
  where
    psql status = do
        let retryNumber = status.rsIterNumber + 1
        when (retryNumber > 1) do
            T.putStrLn [iii| Retrying [#{retryNumber} / #{numRetries}] |]

        hasError <- newIORef False

        lockErrorFound <-
            (Process.toBytesWith (Process.terminateWithSigInt True . Process.waitOnTermination True) "bash" ["-c", [iii| exec psql #{args} 2>&1 |]] :: StreamD.Stream IO Word8)
                & Stream.handle
                    ( \(_ :: Process.ProcessFailure) -> do
                        atomicWriteIORef hasError True
                        return Stream.nil
                    )
                & Stream.tap Stream.Console.Stdio.write
                & Unicode.decodeUtf8
                & StreamD.splitOnSeq (Array.fromList lockTimeoutError) Fold.drain
                & Stream.uncons
                & \unconsedStrm -> do
                    mStrm <- unconsedStrm
                    case mStrm of
                        Nothing -> pure False
                        Just (_, strm) -> not . null <$> Stream.toList strm

        processFailed <- readIORef hasError

        return $
            if processFailed && lockErrorFound
                then ShouldRetry
                else
                    if processFailed
                        then ShouldExit
                        else PsqlSuccess

    shouldRetry _ should =
        case should of
            ShouldRetry -> pure True
            ShouldExit -> pure False
            PsqlSuccess -> pure False

    lockTimeoutError :: String
    lockTimeoutError = "canceling statement due to lock timeout\n"

    numRetries :: Int
    numRetries = 500

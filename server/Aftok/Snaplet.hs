{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TemplateHaskell   #-}

module Aftok.Snaplet where

import           ClassyPrelude

import           Control.Lens
import           Control.Monad.Reader
import           Control.Monad.State
import           Control.Monad.Trans.Except    (runExceptT)
import qualified Data.Aeson                    as A
import           Data.Attoparsec.ByteString    (Parser, parseOnly,
                                                takeByteString)
import           Data.UUID

import           Aftok
import           Aftok.Auction                 (AuctionId (..))
import           Aftok.Database
import           Aftok.Database.PostgreSQL
import           Aftok.Project                 (ProjectId (..))
import           Aftok.Util

import           Snap.Core
import           Snap.Snaplet                  as S
import qualified Snap.Snaplet.Auth             as AU
import           Snap.Snaplet.PostgresqlSimple
import           Snap.Snaplet.Session

data App = App
  { _sess :: Snaplet SessionManager
  , _db   :: Snaplet Postgres
  , _auth :: Snaplet (AU.AuthManager App)
  }
makeLenses ''App

instance HasPostgres (S.Handler b App) where
  getPostgresState = with db get
  setLocalPostgresState s = local (set (db . snapletValue) s)

snapEval :: (MonadSnap m, HasPostgres m) => Program DBOp a -> m a
snapEval p = do
  let handleDBError (OpForbidden (UserId uid) reason) =
        snapError 403 $ tshow reason <> " (User " <> tshow uid <> ")"
      handleDBError (SubjectNotFound) =
        snapError 404 "The subject of the requested operation could not be found."
      handleDBError (EventStorageFailed) =
        snapError 500 "The event submitted could not be saved to the log."

  e <- liftPG $ \conn -> liftIO $ runExceptT (runQDBM conn $ interpret liftdb p)
  either handleDBError pure e

snapError :: MonadSnap m => Int -> Text -> m a
snapError c t = do
  modifyResponse $ setResponseStatus c $ encodeUtf8 t
  writeText $ ((tshow c) <> " - " <> t)
  getResponse >>= finishWith

ok :: MonadSnap m => m a
ok = do
  modifyResponse $ setResponseCode 200
  getResponse >>= finishWith

requireParam :: MonadSnap m => Text -> m ByteString
requireParam name = do
  maybeBytes <- getParam (encodeUtf8 name)
  maybe (snapError 400 $ "Parameter "<> tshow name <>" is required") pure maybeBytes

parseParam :: MonadSnap m
           => Text       -- ^ the name of the parameter to be parsed
           -> Parser a   -- ^ parser for the value of the parameter
           -> m a        -- ^ the parsed value
parseParam name parser = do
  bytes <- requireParam name
  either
    (const . snapError 400 $ "Value of parameter "<> tshow name <>" could not be parsed to a valid value.")
    pure
    (parseOnly parser bytes)

requireId :: MonadSnap m
          => Text        -- ^ name of the parameter
          -> (UUID -> a) -- ^ constructor for the identifier
          -> m a
requireId name f = do
  maybeId <- parseParam name idParser
  maybe (snapError 400 $ "Value of parameter \"" <> name <> "\" is not a valid UUID") pure maybeId
  where
    idParser = do
      bs <- takeByteString
      pure $ f <$> fromASCIIBytes bs

readRequestJSON :: MonadSnap m => Word64 -> m A.Value
readRequestJSON len = do
  requestBody <- A.decode <$> readRequestBody len
  maybe (snapError 400 "Could not interpret request body as a nonempty JSON value.") pure requestBody

requireProjectId :: MonadSnap m => m ProjectId
requireProjectId = requireId "projectId" ProjectId

requireAuctionId :: MonadSnap m => m AuctionId
requireAuctionId = requireId "auctionId" AuctionId


{-# LANGUAGE TemplateHaskell #-}

module Aftok.Snaplet.Auctions
  ( auctionCreateHandler,
    auctionGetHandler,
    auctionBidHandler,
  )
where

import Aftok.Auction
  ( Auction (..),
    AuctionId,
    Bid (..),
    BidId,
  )
import Aftok.Database
  ( createAuction,
    createBid,
    findAuction,
  )
import Aftok.Json
import Aftok.Snaplet
import Aftok.Snaplet.Auth
import Aftok.Types (UserId)
import Aftok.Util (fromMaybeT)
import Bippy.Types (Satoshi (..))
import Control.Monad.Trans.Maybe (mapMaybeT)
import Data.Aeson
import Data.Aeson.Types
import Data.Hourglass.Types (Seconds (..))
import Data.Thyme.Clock as C
import Snap.Snaplet as S

data AuctionCreateRequest = CA {raiseAmount :: Word64, auctionStart :: C.UTCTime, auctionEnd :: C.UTCTime}

auctionCreateParser :: Value -> Parser AuctionCreateRequest
auctionCreateParser = unv1 "auctions" p
  where
    p o = CA <$> o .: "raiseAmount" <*> o .: "auctionStart" <*> o .: "auctionEnd"

bidCreateParser :: UserId -> C.UTCTime -> Value -> Parser Bid
bidCreateParser uid t = unv1 "bids" p
  where
    p o =
      Bid uid
        <$> (Seconds <$> o .: "bidSeconds")
        <*> (Satoshi <$> o .: "bidAmount")
        <*> pure t

auctionCreateHandler :: S.Handler App App AuctionId
auctionCreateHandler = do
  uid <- requireUserId
  pid <- requireProjectId
  requestBody <- readRequestJSON 4096
  req <-
    either (snapError 400 . show) pure $
      parseEither auctionCreateParser requestBody
  t <- liftIO C.getCurrentTime
  snapEval . createAuction $
    Auction
      pid
      uid
      t
      (Satoshi . raiseAmount $ req)
      (auctionStart req)
      (auctionEnd req)

auctionListHandler :: S.Handler App App [Auction]
auctionListHandler = do
  uid <- requireUserId
  pid <- requireProjectId
  snapEval $ listAuctions pid uid

auctionGetHandler :: S.Handler App App Auction
auctionGetHandler = do
  uid <- requireUserId
  aid <- requireAuctionId
  fromMaybeT
    (snapError 404 $ "Auction not found for id " <> show aid)
    (mapMaybeT snapEval $ findAuction aid uid) -- this will verify auction access

auctionBidHandler :: S.Handler App App BidId
auctionBidHandler = do
  uid <- requireUserId
  aid <- requireAuctionId
  timestamp <- liftIO C.getCurrentTime
  requestBody <- readRequestJSON 4096
  bid <-
    either (snapError 400 . show) pure $
      parseEither (bidCreateParser uid timestamp) requestBody
  snapEval $ createBid aid uid bid

{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE DerivingVia           #-}
{-# LANGUAGE EmptyCase             #-}
{-# LANGUAGE EmptyDataDeriving     #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE PolyKinds             #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE UndecidableInstances  #-}

module Cardano.Server.Endpoints.Tx.New where

import           Cardano.Server.Config       (isInactiveNewTx)
import           Cardano.Server.Error        (ConnectionError, Envelope, IsCardanoServerError (..), MkTxError, Throws, toEnvelope)
import           Cardano.Server.Internal     (InputOf, InputWithContext, NetworkM, TxApiRequestOf, checkEndpointAvailability,
                                              serverTrackedAddresses, txEndpointsTxBuilders)
import           Cardano.Server.Tx           (mkBalanceTx)
import           Cardano.Server.Utils.Logger (HasLogger (..), (.<))
import           Control.Monad               (join, liftM3)
import           Control.Monad.Catch         (Exception, MonadThrow (throwM))
import           Data.Aeson                  (ToJSON)
import           Data.Text                   (Text)
import           GHC.Generics                (Generic)
import           Ledger                      (CardanoTx)
import           PlutusAppsExtra.Utils.Tx    (cardanoTxToText)
import           Servant                     (JSON, Post, ReqBody, type (:>))

type NewTxApi reqBody err = "newTx"
    :> Throws err
    :> Throws NewTxApiError
    :> Throws ConnectionError
    :> Throws MkTxError
    :> ReqBody '[JSON] reqBody
    :> Post '[JSON] Text

data NoError deriving (Show, Exception)

instance IsCardanoServerError NoError where
    errStatus = \case
    errMsg = \case

type family TxApiErrorOf api

type CommonErrorsOfNewTxApi = [NewTxApiError, ConnectionError, MkTxError]
type ErrorsOfNewTxApi err = err ': CommonErrorsOfNewTxApi

newtype NewTxApiError = UnserialisableCardanoTx CardanoTx
    deriving stock    (Show, Generic)
    deriving anyclass (ToJSON, Exception)

instance IsCardanoServerError NewTxApiError where
    errStatus _ = toEnum 422
    errMsg (UnserialisableCardanoTx tx) = "Cannot serialise balanced tx:" .< tx

newTxHandler :: forall api. 
    ( Show (TxApiRequestOf api)
    , Show (InputOf api)
    , IsCardanoServerError (TxApiErrorOf api)
    ) => (TxApiRequestOf api -> NetworkM api (InputWithContext api))
    -> TxApiRequestOf api
    -> NetworkM api (Envelope (ErrorsOfNewTxApi (TxApiErrorOf api)) Text)
newTxHandler txEndpointsProcessRequest req = toEnvelope $ do
    logMsg $ "New newTx request received:\n" .< req
    checkEndpointAvailability isInactiveNewTx
    (input, context) <- txEndpointsProcessRequest req
    balancedTx <- join $ liftM3 mkBalanceTx serverTrackedAddresses (pure context) (txEndpointsTxBuilders input)
    case cardanoTxToText balancedTx of
        Just res -> pure res
        Nothing  -> throwM $ UnserialisableCardanoTx balancedTx
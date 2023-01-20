{-# LANGUAGE DeriveAnyClass      #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE DerivingVia         #-}
{-# LANGUAGE ConstraintKinds     #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE NumericUnderscores  #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Cardano.Server.Tx where

import           Control.Exception           (Exception)
import           Cardano.Server.Error        (ExceptionDeriving(..), IsCardanoServerError(..))
import           Cardano.Server.Input        (InputContext (..))
import           Cardano.Server.Internal     (Env(..))
import           Cardano.Server.Utils.Logger (HasLogger(..), logPretty, logSmth)
import           Constraints.OffChain        (utxoProducedPublicKeyTx)
import           Control.Monad.Catch         (MonadThrow(..))
import           Control.Monad.Extra         (mconcatMapM, when, void)
import           Control.Monad.IO.Class      (MonadIO(..))
import           Control.Monad.Reader        (MonadReader, asks)
import           Control.Monad.State         (execState)
import           Data.Aeson                  (ToJSON)
import           Data.Default                (def)
import qualified Data.Map                    as Map
import           Data.Maybe                  (fromJust, isNothing)
import           GHC.Generics                (Generic)
import           Ledger                      (Address, CardanoTx(..), TxOutRef, unspentOutputsTx)
import           Ledger.Ada                  (lovelaceValueOf)
import           Ledger.Tx.CardanoAPI        as CardanoAPI
import           IO.ChainIndex               (getUtxosAt)
import           IO.Time                     (currentTime)
import           IO.Wallet                   (HasWallet(..), signTx, balanceTx, submitTxConfirmed, getWalletAddr, getWalletKeyHashes, getWalletUtxos)
import           Types.Tx                    (TxConstructor (..), TransactionBuilder, selectTxConstructor, mkTxConstructor)
import           Utils.Address               (addressToKeyHashes)
import           Utils.ChainIndex            (filterCleanUtxos)

type MkTxConstraints m s =
    ( HasWallet m
    , HasLogger m
    , MonadReader (Env s) m
    , MonadThrow m
    )

data MkTxError = UnbuildableTx
    deriving (Show, Generic, ToJSON)
    deriving Exception via (ExceptionDeriving MkTxError)

instance IsCardanoServerError MkTxError where
    errStatus _ = toEnum 422
    errMsg _ = "The requested transaction could not be built."

-- TODO: implement two types of balancing
mkBalanceTx :: MkTxConstraints m s
    => [Address]
    -> InputContext
    -> [TransactionBuilder ()]
    -> m CardanoTx
mkBalanceTx addressesTracked InputContext{..} txs = do
    (walletPKH, walletSKC) <- getWalletKeyHashes
    utxosTracked           <- liftIO $ mconcatMapM getUtxosAt addressesTracked
    ct                     <- liftIO currentTime
    ledgerParams           <- asks envLedgerParams
    let utxos = utxosTracked `Map.union` inputUTXO

    let constrInit = mkTxConstructor
            (walletPKH, walletSKC)
            ct
            utxos
        constr = selectTxConstructor $ map (`execState` constrInit) txs
    when (isNothing constr) $ do
        logMsg "\tNo transactions can be constructed. Last error:"
        logSmth $ head $ txConstructorErrors $ last $ map (`execState` constrInit) txs
        throwM UnbuildableTx
    let (lookups, cons) = fromJust $ txConstructorResult $ fromJust constr
    logMsg "\tLookups:"
    logSmth lookups
    logMsg "\tConstraints:"
    logSmth cons

    logMsg "Balancing..."
    balanceTx ledgerParams lookups cons

mkTx :: MkTxConstraints m s
    => [Address]
    -> InputContext
    -> [TransactionBuilder ()]
    -> m CardanoTx
mkTx addressesTracked ctx txs = do
    balancedTx <- mkBalanceTx addressesTracked ctx txs
    logPretty balancedTx
    logMsg "Signing..."
    signedTx <- signTx balancedTx
    logPretty signedTx
    logMsg "Submitting..."
    submitTxConfirmed signedTx
    logMsg "Submited."
    return signedTx

checkForCleanUtxos :: MkTxConstraints m s => m ()
checkForCleanUtxos = do
    addr       <- getWalletAddr
    cleanUtxos <- length . filterCleanUtxos <$> getWalletUtxos
    minUtxos   <- asks envMinUtxosAmount
    when (cleanUtxos < minUtxos) $ do
        logMsg "Address doesn't has enough clean UTXO's."
        void $ mkWalletTxOutRefs addr (cleanUtxos - minUtxos)

mkWalletTxOutRefs :: MkTxConstraints m s => Address -> Int -> m [TxOutRef]
mkWalletTxOutRefs addr n = do
    (pkh, scr) <- maybe (throwM UnbuildableTx) pure $ addressToKeyHashes addr
    let txBuilder = mapM_ (const $ utxoProducedPublicKeyTx pkh scr (lovelaceValueOf 10_000_000) (Nothing :: Maybe ())) [1..n]
    signedTx <- mkTx [addr] def [txBuilder]
    let refs = case signedTx of
            EmulatorTx tx   -> Map.keys $ Ledger.unspentOutputsTx tx
            CardanoApiTx tx -> Map.keys $ CardanoAPI.unspentOutputsTx tx
    pure refs
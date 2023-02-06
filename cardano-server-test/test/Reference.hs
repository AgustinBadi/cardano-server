{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications  #-}

module Reference where

import           Cardano.Server.Example.Main          (ExampleServer)
import           Cardano.Server.Example.OffChain      (testToken)
import           Cardano.Server.Example.OnChain       (testPolicy, testPolicyV)
import           Cardano.Server.Input                 (InputContext (InputContextClient), inputUTXO)
import           Cardano.Server.Internal              (runAppM)
import           Cardano.Server.Tx                    (mkTx)
import           Cardano.Server.Utils.Logger          (HasLogger (..))
import           Control.Monad                        (void)
import           Control.Monad.Cont                   (MonadIO (..))
import           Data.Default                         (def)
import qualified Data.Map                             as Map
import           Ledger                               (CardanoTx, unspentOutputsTx)
import qualified Ledger.Ada                           as Ada
import           Ledger.Tx                            (CardanoTx (..))
import           Ledger.Tx.CardanoAPI                 as CardanoAPI
import           Ledger.Typed.Scripts                 (Any)
import           PlutusAppsExtra.Constraints.OffChain (postMintingPolicyTx, tokensMintedTx)
import           PlutusAppsExtra.IO.Wallet            (getWalletAddr, getWalletUtxos)
import qualified PlutusTx.Prelude                     as Plutus

postReferenceScript :: IO CardanoTx
postReferenceScript = runAppM @ExampleServer $ do
    addr <- getWalletAddr
    mkTx [] def
        [ postMintingPolicyTx
            addr
            testPolicyV
            (Nothing :: Maybe ())
            (Ada.adaValueOf 0)
        ]

runReferenceTest :: IO ()
runReferenceTest = void $ runAppM @ExampleServer $ do
    ctx <- liftIO postReferenceScript
    let ref = head $ case ctx of
            EmulatorTx tx   -> Map.keys $ Ledger.unspentOutputsTx tx
            CardanoApiTx tx -> Map.keys $ CardanoAPI.unspentOutputsTx tx
    
    addr  <- getWalletAddr
    utxos <- getWalletUtxos
    let context = InputContextClient utxos utxos (head $ Map.keys utxos) addr
    logMsg "\n\n\n\t\t\tMINT1:"
    mkTest "token1" ref context
    
    addr'  <- getWalletAddr
    utxos' <- getWalletUtxos
    let context' = InputContextClient utxos' utxos' (head $ Map.keys utxos') addr'
    logMsg "\n\n\n\t\t\tMINT2:"
    mkTest "token2" ref context'
  where
    mkTest token ref context = mkTx
        []
        context
        [
            tokensMintedTx
            testPolicyV
            ([token] :: [Plutus.BuiltinByteString])
            (Plutus.sum $ map testToken [token])
        ]
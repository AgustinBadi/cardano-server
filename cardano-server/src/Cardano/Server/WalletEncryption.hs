{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE DeriveAnyClass      #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}

module Cardano.Server.WalletEncryption where

import           Cardano.Mnemonic          (MkSomeMnemonic (mkSomeMnemonic), MkSomeMnemonicError, SomeMnemonic (..),
                                            mnemonicToText)
import           Control.Exception         (Exception)
import           Crypto.Cipher.AES         (AES256)
import           Crypto.Cipher.Types       (BlockCipher (..), Cipher (cipherInit), IV, makeIV)
import           Crypto.Error              (CryptoError (..), CryptoFailable (..))
import           Crypto.Hash               (SHA1)
import qualified Crypto.Hash               as Hash
import qualified Crypto.Random.Types       as CRT
import           Data.Aeson                (FromJSON (..), KeyValue ((.=)), ToJSON (..), (.:))
import qualified Data.Aeson                as J
import           Data.Bifunctor            (Bifunctor (bimap, first))
import           Data.ByteArray            (ByteArray)
import qualified Data.ByteArray            as BA
import           Data.ByteString           (ByteString)
import qualified Data.ByteString           as BS
import           Data.Either.Extra         (maybeToEither)
import           Data.String               (IsString (..))
import           Data.Text                 (Text)
import qualified Data.Text                 as T
import           Data.Text.Class           (FromText (fromText), TextDecodingError, ToText (toText))
import qualified Data.Text.Encoding        as T
import           GHC.Generics              (Generic)
import           PlutusAppsExtra.IO.Wallet (RestoredWallet (..))
import qualified Text.Hex                  as T

-- | The passphrase must contain only utf8 characters.
data EncryptedWallet = EncryptedWallet
    { ewName     :: Text
    , ewIVAES256 :: IV AES256
    , ewMnemonic :: ByteString
    } deriving (Generic, Eq)

instance ToJSON EncryptedWallet where
    toJSON EncryptedWallet{..} = J.object
        [ "name"     .= ewName
        , "IV"       .= T.encodeHex (BS.pack $ BA.unpack ewIVAES256)
        , "mnemonic" .= T.encodeHex ewMnemonic
        ]

instance FromJSON EncryptedWallet where
    parseJSON = J.withObject "encrypted wallet" $ \o -> do
        let mbFail f = maybe (fail f) pure
        ewName     <- o .: "name"
        ewIVAES256 <- o .: "IV" 
            >>= mbFail "decodeHex IV" . T.decodeHex 
            >>= mbFail "make IV" . makeIV
        ewMnemonic <- o .: "mnemonic" 
            >>= mbFail "decodeHex mnemonic" . T.decodeHex
        pure EncryptedWallet{..}

instance Show EncryptedWallet where
    show EncryptedWallet{..} = T.unpack ewName <> ":\n" <> show ewMnemonic

data WalletEncryptionError
    = IVInitializingError
    | SomeCryptoError CryptoError
    | PassphraseDecodingError TextDecodingError
    | MnemonicDecodingError (MkSomeMnemonicError '[24])
    deriving (Show, Exception, Eq)

data Key c a where
    Key :: (BlockCipher c, ByteArray a) => a -> Key c a

encryptWallet :: RestoredWallet -> IO (Either WalletEncryptionError EncryptedWallet)
encryptWallet RestoredWallet{..} = do
    eitherInitIV <- maybeToEither IVInitializingError <$> genRandomIV (undefined :: AES256)
    pure $ do
        initIV <- eitherInitIV
        let msg = mnemonicToBytes mnemonicSentence
            secretKey = passphraseTextToKey $ toText passphrase
        msgE <- bimap SomeCryptoError (\c -> ctrCombine c initIV msg) $ initCipher secretKey
        Right $ EncryptedWallet name initIV msgE

decryptWallet :: EncryptedWallet -> Text -> Either WalletEncryptionError RestoredWallet
decryptWallet EncryptedWallet{..} passphraseText = do
    let secretKey = passphraseTextToKey passphraseText
    mnemonicBS <- bimap SomeCryptoError (\c -> ctrCombine c ewIVAES256 ewMnemonic) $ initCipher secretKey
    passphrase <- first PassphraseDecodingError $ fromText passphraseText
    mnemonic   <- first MnemonicDecodingError $ bytesToMnemonic mnemonicBS
    pure $ RestoredWallet ewName mnemonic passphrase

passphraseTextToKey :: Text -> Key AES256 ByteString
passphraseTextToKey = Key . BS.take 32 . fromString . show . Hash.hash @ByteString @SHA1 . fromString . T.unpack

mnemonicToBytes :: SomeMnemonic -> ByteString
mnemonicToBytes (SomeMnemonic m) = T.encodeUtf8 $ T.unwords $ mnemonicToText m

bytesToMnemonic :: ByteString -> Either (MkSomeMnemonicError '[24]) SomeMnemonic
bytesToMnemonic = mkSomeMnemonic @'[24] . T.words . T.decodeUtf8

genRandomIV :: forall m c. (CRT.MonadRandom m, BlockCipher c) => c -> m (Maybe (IV c))
genRandomIV _ = do
    bytes :: ByteString <- CRT.getRandomBytes $ blockSize (undefined :: c)
    return $ makeIV bytes

initCipher :: (BlockCipher c, ByteArray a) => Key c a -> Either CryptoError c
initCipher (Key k) = case cipherInit k of
    CryptoFailed e -> Left e
    CryptoPassed a -> Right a
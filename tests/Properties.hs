{-# LANGUAGE OverloadedStrings, RecordWildCards, ScopedTypeVariables #-}

module Properties (tests) where

import Data.Aeson (eitherDecode)
import Data.Aeson.Encode (encode, encodeToBuilder)
import Data.Aeson.Internal (IResult(..), formatError, ifromJSON, iparse)
import Data.Aeson.Parser (value)
import Data.Aeson.Types
import Data.ByteString.Builder (toLazyByteString)
import Data.Int (Int8)
import Data.Time (UTCTime, ZonedTime)
import Encoders
import Instances ()
import Properties.ZonedTime (zonedTimeToJSON)
import Test.Framework (Test, testGroup)
import Test.Framework.Providers.QuickCheck2 (testProperty)
import Test.QuickCheck (Arbitrary(..), Property, (===))
import Types
import qualified Data.Attoparsec.Lazy as L
import qualified Data.ByteString.Lazy.Char8 as L
import qualified Data.HashMap.Strict as H
import qualified Data.Map as Map
import qualified Data.Text as T
import qualified Data.Vector as V

encodeDouble :: Double -> Double -> Property
encodeDouble num denom
    | isInfinite d || isNaN d = encode d === "null"
    | otherwise               = (read . L.unpack . encode) d === d
  where d = num / denom

encodeInteger :: Integer -> Property
encodeInteger i = encode i === L.pack (show i)

toParseJSON :: (Arbitrary a, Eq a, Show a) =>
               (Value -> Parser a) -> (a -> Value) -> a -> Property
toParseJSON parsejson tojson x =
    case iparse parsejson . tojson $ x of
      IError path msg -> failure "parse" (formatError path msg) x
      ISuccess x'     -> x === x'

roundTrip :: (FromJSON a, ToJSON a, Show a) =>
             (a -> a -> Property) -> a -> a -> Property
roundTrip eq _ i =
    case fmap ifromJSON . L.parse value . encode . toJSON $ i of
      L.Done _ (ISuccess v)      -> v `eq` i
      L.Done _ (IError path err) -> failure "fromJSON" (formatError path err) i
      L.Fail _ _ err             -> failure "parse" err i

roundTripEq :: (Eq a, FromJSON a, ToJSON a, Show a) => a -> a -> Property
roundTripEq x y = roundTrip (===) x y

toFromJSON :: (Arbitrary a, Eq a, FromJSON a, ToJSON a, Show a) => a -> Property
toFromJSON x = case ifromJSON (toJSON x) of
                IError path err -> failure "fromJSON" (formatError path err) x
                ISuccess x'     -> x === x'

modifyFailureProp :: String -> String -> Bool
modifyFailureProp orig added =
    result == Error (added ++ orig)
  where
    parser = const $ modifyFailure (added ++) $ fail orig
    result :: Result ()
    result = parse parser ()

-- | Perform a bit-for-bit comparison of two encoding methods.
sameAs :: (a -> Value) -> (a -> Encoding) -> a -> Property
sameAs toVal toEnc v =
  toLazyByteString (encodeToBuilder (toVal v)) ===
  toLazyByteString (fromEncoding (toEnc v))

-- | Behaves like 'sameAs', but compares decoded values to account for
-- HashMap-driven variation in JSON object key ordering.
sameAsV :: (a -> Value) -> (a -> Encoding) -> a -> Property
sameAsV toVal toEnc v =
  eitherDecode (toLazyByteString (fromEncoding (toEnc v))) === Right (toVal v)

type P6 = Product6 Int Bool String (Approx Double) (Int, Approx Double) ()
type S4 = Sum4 Int8 ZonedTime T.Text (Map.Map String Int)

--------------------------------------------------------------------------------
-- Value properties
--------------------------------------------------------------------------------

isString :: Value -> Bool
isString (String _) = True
isString _          = False

is2ElemArray :: Value -> Bool
is2ElemArray (Array v) = V.length v == 2 && isString (V.head v)
is2ElemArray _         = False

isTaggedObjectValue :: Value -> Bool
isTaggedObjectValue (Object obj) = "tag"      `H.member` obj &&
                                   "contents" `H.member` obj
isTaggedObjectValue _            = False

isTaggedObject :: Value -> Bool
isTaggedObject (Object obj) = "tag" `H.member` obj
isTaggedObject _            = False

isObjectWithSingleField :: Value -> Bool
isObjectWithSingleField (Object obj) = H.size obj == 1
isObjectWithSingleField _            = False

--------------------------------------------------------------------------------

tests :: Test
tests = testGroup "properties" [
  testGroup "encode" [
      testProperty "encodeDouble" encodeDouble
    , testProperty "encodeInteger" encodeInteger
    ]
  , testGroup "roundTrip" [
      testProperty "Bool" $ roundTripEq True
    , testProperty "Double" $ roundTripEq (1 :: Approx Double)
    , testProperty "Int" $ roundTripEq (1 :: Int)
    , testProperty "Integer" $ roundTripEq (1 :: Integer)
    , testProperty "String" $ roundTripEq ("" :: String)
    , testProperty "Text" $ roundTripEq T.empty
    , testProperty "Foo" $ roundTripEq (undefined :: Foo)
    , testProperty "DotNetTime" $ roundTripEq (undefined :: DotNetTime)
    , testProperty "UTCTime" $ roundTripEq (undefined :: UTCTime)
    , testProperty "ZonedTime" $ roundTripEq (undefined :: ZonedTime)
    , testGroup "ghcGenerics" [
        testProperty "OneConstructor" $ roundTripEq OneConstructor
      , testProperty "Product2" $ roundTripEq (undefined :: Product2 Int Bool)
      , testProperty "Product6" $ roundTripEq (undefined :: P6)
      , testProperty "Sum4" $ roundTripEq (undefined :: S4)
      ]
    ]
  , testGroup "toFromJSON" [
      testProperty "Integer" (toFromJSON :: Integer -> Property)
    , testProperty "Double" (toFromJSON :: Double -> Property)
    , testProperty "Maybe Integer" (toFromJSON :: Maybe Integer -> Property)
    , testProperty "Either Integer Double" (toFromJSON :: Either Integer Double -> Property)
    , testProperty "Either Integer Integer" (toFromJSON :: Either Integer Integer -> Property)
    , zonedTimeToJSON
    ]
  , testGroup "failure messages" [
      testProperty "modify failure" modifyFailureProp
    ]
  , testGroup "template-haskell" [
      testGroup "toJSON" [
        testGroup "Nullary" [
            testProperty "string" (isString . thNullaryToJSONString)
          , testProperty "2ElemArray" (is2ElemArray . thNullaryToJSON2ElemArray)
          , testProperty "TaggedObject" (isTaggedObjectValue . thNullaryToJSONTaggedObject)
          , testProperty "ObjectWithSingleField" (isObjectWithSingleField . thNullaryToJSONObjectWithSingleField)

          , testGroup "roundTrip" [
              testProperty "string" (toParseJSON thNullaryParseJSONString thNullaryToJSONString)
            , testProperty "2ElemArray" (toParseJSON thNullaryParseJSON2ElemArray thNullaryToJSON2ElemArray)
            , testProperty "TaggedObject" (toParseJSON thNullaryParseJSONTaggedObject thNullaryToJSONTaggedObject)
            , testProperty "ObjectWithSingleField" (toParseJSON thNullaryParseJSONObjectWithSingleField thNullaryToJSONObjectWithSingleField)
            ]
        ]
      , testGroup "SomeType" [
          testProperty "2ElemArray" (is2ElemArray . thSomeTypeToJSON2ElemArray)
        , testProperty "TaggedObject" (isTaggedObject . thSomeTypeToJSONTaggedObject)
        , testProperty "ObjectWithSingleField" (isObjectWithSingleField . thSomeTypeToJSONObjectWithSingleField)
        , testGroup "roundTrip" [
            testProperty "2ElemArray" (toParseJSON thSomeTypeParseJSON2ElemArray thSomeTypeToJSON2ElemArray)
          , testProperty "TaggedObject" (toParseJSON thSomeTypeParseJSONTaggedObject thSomeTypeToJSONTaggedObject)
          , testProperty "ObjectWithSingleField" (toParseJSON thSomeTypeParseJSONObjectWithSingleField thSomeTypeToJSONObjectWithSingleField)
          ]
       , testGroup "Approx" [
            testProperty "string"                (isString                . thApproxToJSONUnwrap)
          , testProperty "ObjectWithSingleField" (isObjectWithSingleField . thApproxToJSONDefault)
          , testGroup "roundTrip" [
                testProperty "string"                (toParseJSON thApproxParseJSONUnwrap  thApproxToJSONUnwrap)
              , testProperty "ObjectWithSingleField" (toParseJSON thApproxParseJSONDefault thApproxToJSONDefault)
            ]
          ]
        ]
      ]
    , testGroup "toEncoding" [
        testProperty "NullaryString" $
        thNullaryToJSONString `sameAs` thNullaryToEncodingString
      , testProperty "Nullary2ElemArray" $
        thNullaryToJSON2ElemArray `sameAs` thNullaryToEncoding2ElemArray
      , testProperty "NullaryTaggedObject" $
        thNullaryToJSONTaggedObject `sameAs` thNullaryToEncodingTaggedObject
      , testProperty "NullaryObjectWithSingleField" $
        thNullaryToJSONObjectWithSingleField `sameAs`
        thNullaryToEncodingObjectWithSingleField
      , testProperty "ApproxUnwrap" $
        thApproxToJSONUnwrap `sameAs` thApproxToEncodingUnwrap
      , testProperty "ApproxDefault" $
        thApproxToJSONDefault `sameAs` thApproxToEncodingDefault
      , testProperty "SomeType2ElemArray" $
        thSomeTypeToJSON2ElemArray `sameAsV` thSomeTypeToEncoding2ElemArray
      , testProperty "SomeTypeTaggedObject" $
        thSomeTypeToJSONTaggedObject `sameAsV` thSomeTypeToEncodingTaggedObject
      , testProperty "SomeTypeObjectWithSingleField" $
        thSomeTypeToJSONObjectWithSingleField `sameAsV`
        thSomeTypeToEncodingObjectWithSingleField
      ]
    ]
  ]

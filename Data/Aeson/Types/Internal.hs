{-# LANGUAGE DeriveDataTypeable, GeneralizedNewtypeDeriving, Rank2Types,
    RecordWildCards #-}

-- |
-- Module:      Data.Aeson.Types.Internal
-- Copyright:   (c) 2011-2015 Bryan O'Sullivan
--              (c) 2011 MailRank, Inc.
-- License:     Apache
-- Maintainer:  Bryan O'Sullivan <bos@serpentine.com>
-- Stability:   experimental
-- Portability: portable
--
-- Types for working with JSON data.

module Data.Aeson.Types.Internal
    (
    -- * Core JSON types
      Value(..)
    , Encoding(..)
    , Series(..)
    , Array
    , emptyArray, isEmptyArray
    , Pair
    , Object
    , emptyObject
    -- * Type conversion
    , Parser
    , Result(..)
    , IResult(..)
    , JSONPathElement(..)
    , JSONPath
    , iparse
    , parse
    , parseEither
    , parseMaybe
    , modifyFailure
    , formatError
    , (<?>)
    -- * Constructors and accessors
    , object

    -- * Generic and TH encoding configuration
    , Options(..)
    , SumEncoding(..)
    , defaultOptions
    , defaultTaggedObject

    -- * Used for changing CamelCase names into something else.
    , camelTo

    -- * Other types
    , DotNetTime(..)
    ) where

import Control.Applicative
import Control.Monad
import Control.DeepSeq (NFData(..))
import Data.ByteString.Builder (Builder, char7, toLazyByteString)
import Data.Char (toLower, isUpper)
import Data.Scientific (Scientific)
import Data.Hashable (Hashable(..))
import Data.Data (Data)
import Data.HashMap.Strict (HashMap)
import Data.Monoid (Monoid(..), (<>))
import Data.String (IsString(..))
import Data.Text (Text, pack, unpack)
import Data.Time (UTCTime)
import Data.Time.Format (FormatTime)
import Data.Typeable (Typeable)
import Data.Vector (Vector)
import qualified Data.HashMap.Strict as H
import qualified Data.Vector as V

-- | Elements of a JSON path used to describe the location of an
-- error.
data JSONPathElement = Key Text
                       -- ^ JSON path element of a key into an object,
                       -- \"object.key\".
                     | Index {-# UNPACK #-} !Int
                       -- ^ JSON path element of an index into an
                       -- array, \"array[index]\".
                       deriving (Eq, Show, Typeable)
type JSONPath = [JSONPathElement]

-- | The internal result of running a 'Parser'.
data IResult a = IError JSONPath String
               | ISuccess a
               deriving (Eq, Show, Typeable)

-- | The result of running a 'Parser'.
data Result a = Error String
              | Success a
                deriving (Eq, Show, Typeable)

instance NFData JSONPathElement where
  rnf (Key t)   = rnf t
  rnf (Index i) = rnf i

instance (NFData a) => NFData (IResult a) where
    rnf (ISuccess a)      = rnf a
    rnf (IError path err) = rnf path `seq` rnf err

instance (NFData a) => NFData (Result a) where
    rnf (Success a) = rnf a
    rnf (Error err) = rnf err

instance Functor IResult where
    fmap f (ISuccess a)      = ISuccess (f a)
    fmap _ (IError path err) = IError path err
    {-# INLINE fmap #-}

instance Functor Result where
    fmap f (Success a) = Success (f a)
    fmap _ (Error err) = Error err
    {-# INLINE fmap #-}

instance Monad IResult where
    return = ISuccess
    {-# INLINE return #-}

    ISuccess a      >>= k = k a
    IError path err >>= _ = IError path err
    {-# INLINE (>>=) #-}

    fail err = IError [] err
    {-# INLINE fail #-}

instance Monad Result where
    return = Success
    {-# INLINE return #-}

    Success a >>= k = k a
    Error err >>= _ = Error err
    {-# INLINE (>>=) #-}

    fail err = Error err
    {-# INLINE fail #-}

instance Applicative IResult where
    pure  = return
    {-# INLINE pure #-}
    (<*>) = ap
    {-# INLINE (<*>) #-}

instance Applicative Result where
    pure  = return
    {-# INLINE pure #-}
    (<*>) = ap
    {-# INLINE (<*>) #-}

instance MonadPlus IResult where
    mzero = fail "mzero"
    {-# INLINE mzero #-}
    mplus a@(ISuccess _) _ = a
    mplus _ b             = b
    {-# INLINE mplus #-}

instance MonadPlus Result where
    mzero = fail "mzero"
    {-# INLINE mzero #-}
    mplus a@(Success _) _ = a
    mplus _ b             = b
    {-# INLINE mplus #-}

instance Alternative IResult where
    empty = mzero
    {-# INLINE empty #-}
    (<|>) = mplus
    {-# INLINE (<|>) #-}

instance Alternative Result where
    empty = mzero
    {-# INLINE empty #-}
    (<|>) = mplus
    {-# INLINE (<|>) #-}

instance Monoid (IResult a) where
    mempty  = fail "mempty"
    {-# INLINE mempty #-}
    mappend = mplus
    {-# INLINE mappend #-}

instance Monoid (Result a) where
    mempty  = fail "mempty"
    {-# INLINE mempty #-}
    mappend = mplus
    {-# INLINE mappend #-}

-- | Failure continuation.
type Failure f r   = JSONPath -> String -> f r
-- | Success continuation.
type Success a f r = a -> f r

-- | A continuation-based parser type.
newtype Parser a = Parser {
      runParser :: forall f r.
                   JSONPath
                -> Failure f r
                -> Success a f r
                -> f r
    }

instance Monad Parser where
    m >>= g = Parser $ \path kf ks -> let ks' a = runParser (g a) path kf ks
                                       in runParser m path kf ks'
    {-# INLINE (>>=) #-}
    return a = Parser $ \_path _kf ks -> ks a
    {-# INLINE return #-}
    fail msg = Parser $ \path kf _ks -> kf (reverse path) msg
    {-# INLINE fail #-}

instance Functor Parser where
    fmap f m = Parser $ \path kf ks -> let ks' a = ks (f a)
                                        in runParser m path kf ks'
    {-# INLINE fmap #-}

instance Applicative Parser where
    pure  = return
    {-# INLINE pure #-}
    (<*>) = apP
    {-# INLINE (<*>) #-}

instance Alternative Parser where
    empty = fail "empty"
    {-# INLINE empty #-}
    (<|>) = mplus
    {-# INLINE (<|>) #-}

instance MonadPlus Parser where
    mzero = fail "mzero"
    {-# INLINE mzero #-}
    mplus a b = Parser $ \path kf ks -> let kf' _ _ = runParser b path kf ks
                                         in runParser a path kf' ks
    {-# INLINE mplus #-}

instance Monoid (Parser a) where
    mempty  = fail "mempty"
    {-# INLINE mempty #-}
    mappend = mplus
    {-# INLINE mappend #-}

apP :: Parser (a -> b) -> Parser a -> Parser b
apP d e = do
  b <- d
  a <- e
  return (b a)
{-# INLINE apP #-}

-- | A JSON \"object\" (key\/value map).
type Object = HashMap Text Value

-- | A JSON \"array\" (sequence).
type Array = Vector Value

-- | A JSON value represented as a Haskell value.
data Value = Object !Object
           | Array !Array
           | String !Text
           | Number !Scientific
           | Bool !Bool
           | Null
             deriving (Eq, Read, Show, Typeable, Data)

-- | An encoding of a JSON value.
newtype Encoding = Encoding {
      fromEncoding :: Builder
    } deriving (Monoid)

instance Show Encoding where
    show (Encoding e) = show (toLazyByteString e)

instance Eq Encoding where
    Encoding a == Encoding b = toLazyByteString a == toLazyByteString b

instance Ord Encoding where
    compare (Encoding a) (Encoding b) =
      compare (toLazyByteString a) (toLazyByteString b)

-- | A series of values that, when encoded, should be separated by commas.
data Series = Empty
            | Value Encoding
            deriving (Typeable)

instance Monoid Series where
    mempty              = Empty

    mappend Empty a     = a
    mappend (Value a) b =
        Value $
        a <> case b of
               Empty   -> mempty
               Value c -> Encoding (char7 ',') <> c

-- | A newtype wrapper for 'UTCTime' that uses the same non-standard
-- serialization format as Microsoft .NET, whose @System.DateTime@
-- type is by default serialized to JSON as in the following example:
--
-- > /Date(1302547608878)/
--
-- The number represents milliseconds since the Unix epoch.
newtype DotNetTime = DotNetTime {
      fromDotNetTime :: UTCTime
    } deriving (Eq, Ord, Read, Show, Typeable, FormatTime)

instance NFData Value where
    rnf (Object o) = rnf o
    rnf (Array a)  = V.foldl' (\x y -> rnf y `seq` x) () a
    rnf (String s) = rnf s
    rnf (Number n) = rnf n
    rnf (Bool b)   = rnf b
    rnf Null       = ()

instance IsString Value where
    fromString = String . pack
    {-# INLINE fromString #-}

hashValue :: Int -> Value -> Int
hashValue s (Object o)   = H.foldl' hashWithSalt
                              (s `hashWithSalt` (0::Int)) o
hashValue s (Array a)    = V.foldl' hashWithSalt
                              (s `hashWithSalt` (1::Int)) a
hashValue s (String str) = s `hashWithSalt` (2::Int) `hashWithSalt` str
hashValue s (Number n)   = s `hashWithSalt` (3::Int) `hashWithSalt` n
hashValue s (Bool b)     = s `hashWithSalt` (4::Int) `hashWithSalt` b
hashValue s Null         = s `hashWithSalt` (5::Int)

instance Hashable Value where
    hashWithSalt = hashValue

-- | The empty array.
emptyArray :: Value
emptyArray = Array V.empty

-- | Determines if the 'Value' is an empty 'Array'.
-- Note that: @isEmptyArray 'emptyArray'@.
isEmptyArray :: Value -> Bool
isEmptyArray (Array arr) = V.null arr
isEmptyArray _ = False

-- | The empty object.
emptyObject :: Value
emptyObject = Object H.empty

-- | Run a 'Parser'.
parse :: (a -> Parser b) -> a -> Result b
parse m v = runParser (m v) [] (const Error) Success
{-# INLINE parse #-}

-- | Run a 'Parser'.
iparse :: (a -> Parser b) -> a -> IResult b
iparse m v = runParser (m v) [] IError ISuccess
{-# INLINE iparse #-}

-- | Run a 'Parser' with a 'Maybe' result type.
parseMaybe :: (a -> Parser b) -> a -> Maybe b
parseMaybe m v = runParser (m v) [] (\_ _ -> Nothing) Just
{-# INLINE parseMaybe #-}

-- | Run a 'Parser' with an 'Either' result type.
parseEither :: (a -> Parser b) -> a -> Either String b
parseEither m v = runParser (m v) [] onError Right
  where onError path msg = Left (formatError path msg)
{-# INLINE parseEither #-}

-- | Annotate an error message with a
-- <http://goessner.net/articles/JsonPath/ JSONPath> error location.
formatError :: JSONPath -> String -> String
formatError path msg = "Error in " ++ (format "$" path) ++ ": " ++ msg
  where
    format pfx []                = pfx
    format pfx (Index idx:parts) = format (pfx ++ "[" ++ show idx ++ "]") parts
    format pfx (Key key:parts)   = format (pfx ++ "." ++ unpack key) parts

-- | A key\/value pair for an 'Object'.
type Pair = (Text, Value)

-- | Create a 'Value' from a list of name\/value 'Pair's.  If duplicate
-- keys arise, earlier keys and their associated values win.
object :: [Pair] -> Value
object = Object . H.fromList
{-# INLINE object #-}

-- | Add JSON Path context to a parser
--
-- When parsing complex structure it helps to annotate (sub)parsers
-- with context so that if error occurs you can find it's location.
--
-- > withObject "Person" $ \o ->
-- >   Person
-- >     <$> o .: "name" <?> Key "name"
-- >     <*> o .: "age"  <?> Key "age"
--
-- (except for standard methods like '(.:)' already do that)
--
-- After that in case of error you will get a JSON Path location of that error.
--
-- Since 0.9
(<?>) :: Parser a -> JSONPathElement -> Parser a
p <?> pathElem = Parser $ \path kf ks -> runParser p (pathElem:path) kf ks

-- | If the inner @Parser@ failed, modify the failure message using the
-- provided function. This allows you to create more descriptive error messages.
-- For example:
--
-- > parseJSON (Object o) = modifyFailure
-- >     ("Parsing of the Foo value failed: " ++)
-- >     (Foo <$> o .: "someField")
--
-- Since 0.6.2.0
modifyFailure :: (String -> String) -> Parser a -> Parser a
modifyFailure f (Parser p) = Parser $ \path kf ks -> p path (\p' m -> kf p' (f m)) ks

--------------------------------------------------------------------------------
-- Generic and TH encoding configuration
--------------------------------------------------------------------------------

-- | Options that specify how to encode\/decode your datatype to\/from JSON.
data Options = Options
    { fieldLabelModifier :: String -> String
      -- ^ Function applied to field labels.
      -- Handy for removing common record prefixes for example.
    , constructorTagModifier :: String -> String
      -- ^ Function applied to constructor tags which could be handy
      -- for lower-casing them for example.
    , allNullaryToStringTag :: Bool
      -- ^ If 'True' the constructors of a datatype, with /all/
      -- nullary constructors, will be encoded to just a string with
      -- the constructor tag. If 'False' the encoding will always
      -- follow the `sumEncoding`.
    , omitNothingFields :: Bool
      -- ^ If 'True' record fields with a 'Nothing' value will be
      -- omitted from the resulting object. If 'False' the resulting
      -- object will include those fields mapping to @null@.
    , sumEncoding :: SumEncoding
      -- ^ Specifies how to encode constructors of a sum datatype.
    , unwrapUnaryRecords :: Bool
      -- ^ Hide the field name when a record constructor has only one
      -- field, like a newtype.
    }

instance Show Options where
  show Options{..} = "Options {" ++
    "fieldLabelModifier =~ " ++
      show (fieldLabelModifier "exampleField") ++ ", " ++
    "constructorTagModifier =~ " ++
      show (constructorTagModifier "ExampleConstructor") ++ ", " ++
    "allNullaryToStringTag = " ++ show allNullaryToStringTag ++ ", " ++
    "omitNothingFields = " ++ show omitNothingFields ++ ", " ++
    "sumEncoding = " ++ show sumEncoding ++ ", " ++
    "unwrapUnaryRecords = " ++ show unwrapUnaryRecords ++
    "}"

-- | Specifies how to encode constructors of a sum datatype.
data SumEncoding =
    TaggedObject { tagFieldName      :: String
                 , contentsFieldName :: String
                 }
    -- ^ A constructor will be encoded to an object with a field
    -- 'tagFieldName' which specifies the constructor tag (modified by
    -- the 'constructorTagModifier'). If the constructor is a record
    -- the encoded record fields will be unpacked into this object. So
    -- make sure that your record doesn't have a field with the same
    -- label as the 'tagFieldName'. Otherwise the tag gets overwritten
    -- by the encoded value of that field! If the constructor is not a
    -- record the encoded constructor contents will be stored under
    -- the 'contentsFieldName' field.
  | ObjectWithSingleField
    -- ^ A constructor will be encoded to an object with a single
    -- field named after the constructor tag (modified by the
    -- 'constructorTagModifier') which maps to the encoded contents of
    -- the constructor.
  | TwoElemArray
    -- ^ A constructor will be encoded to a 2-element array where the
    -- first element is the tag of the constructor (modified by the
    -- 'constructorTagModifier') and the second element the encoded
    -- contents of the constructor.
    deriving (Eq, Show)

-- | Default encoding 'Options':
--
-- @
-- 'Options'
-- { 'fieldLabelModifier'      = id
-- , 'constructorTagModifier'  = id
-- , 'allNullaryToStringTag'   = True
-- , 'omitNothingFields'       = False
-- , 'sumEncoding'             = 'defaultTaggedObject'
-- }
-- @
defaultOptions :: Options
defaultOptions = Options
                 { fieldLabelModifier      = id
                 , constructorTagModifier  = id
                 , allNullaryToStringTag   = True
                 , omitNothingFields       = False
                 , sumEncoding             = defaultTaggedObject
                 , unwrapUnaryRecords      = False
                 }

-- | Default 'TaggedObject' 'SumEncoding' options:
--
-- @
-- defaultTaggedObject = 'TaggedObject'
--                       { 'tagFieldName'      = \"tag\"
--                       , 'contentsFieldName' = \"contents\"
--                       }
-- @
defaultTaggedObject :: SumEncoding
defaultTaggedObject = TaggedObject
                      { tagFieldName      = "tag"
                      , contentsFieldName = "contents"
                      }

-- | Converts from CamelCase to another lower case, interspersing
--   the character between all capital letters and their previous
--   entries, except those capital letters that appear together,
--   like 'API'.
--
--   For use by Aeson template haskell calls.
--
--   > camelTo '_' 'CamelCaseAPI' == "camel_case_api"
camelTo :: Char -> String -> String
camelTo c = lastWasCap True
  where
    lastWasCap :: Bool    -- ^ Previous was a capital letter
              -> String  -- ^ The remaining string
              -> String
    lastWasCap _    []           = []
    lastWasCap prev (x : xs)     = if isUpper x
                                      then if prev
                                             then toLower x : lastWasCap True xs
                                             else c : toLower x : lastWasCap True xs
                                      else x : lastWasCap False xs

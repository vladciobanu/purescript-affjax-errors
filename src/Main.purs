module Main where

import Control.Monad.Aff (Aff, launchAff_)
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Class (liftEff)
import Control.Monad.Eff.Console (CONSOLE, log)
import Data.Either (Either(Left, Right))
import Data.HTTP.Method (Method(..))
import Data.Symbol (SProxy(..))
import Data.Variant (Variant, case_, expand, inj, on)
import Network.HTTP.Affjax (AJAX, affjax, defaultRequest)
import Network.HTTP.StatusCode (StatusCode(..))
import Prelude (Unit, bind, const, discard, otherwise, pure, unit, (#), (<>), ($), (==), (<<<))
import Simple as S
import Variant (runAffjaxWithError)

------------------------------------------------------------------------------------------
-- Simple version
------------------------------------------------------------------------------------------

-- | Error type used for `getFile`.
data BasicError = Unauthorized | ServerError | ParseError

-- | Need an instance to be able to use the simple mechanism for translating errors.
instance basicErrorMapStatusCode :: S.MapStatusCode BasicError where
  mapStatusCode (StatusCode n)
    | n == 401  = Unauthorized
    | otherwise = ServerError
  mapParserError _ = ParseError

-- | Actual Ajax call helper, uses `decodeWithError` with the help of the `MapStatusCode`
-- | instance above.
getFile :: forall eff. String -> Aff (ajax :: AJAX | eff) (Either BasicError String)
getFile s = do
  res <- affjax $ defaultRequest
    { url = "simpleAPI/" <> s
    , method = Left GET
    }
  pure $ S.decodeWithError res

-- | Let's assume we have a different type of error with an additional `NotFound` option.
data SomeError = NotFound | SomeBasicError BasicError

-- | We can construct an instance as well.
instance someErrorMapStatusCode :: S.MapStatusCode SomeError where
  mapStatusCode sc@(StatusCode n)
    | n == 404  = NotFound
    | otherwise = SomeBasicError $ S.mapStatusCode sc
  mapParserError = SomeBasicError <<< S.mapParserError

-- | And create a new API endpoint.
getFilePlus :: forall eff. String -> Aff (ajax :: AJAX | eff) (Either SomeError String)
getFilePlus s = do
  res <- affjax $ defaultRequest
    { url = s
    , method = Left GET
    }
  pure $ S.decodeWithError res

------------------------------------------------------------------------------------------
-- Variant version
------------------------------------------------------------------------------------------

-- | A few helpers to make things easier.
_unAuthorized = SProxy :: SProxy "unAuthorized"
_serverError  = SProxy :: SProxy "serverError"
_parseError   = SProxy :: SProxy "parseError"

-- | Parse error could be more complex than this. We could store the parse error in a String,
-- | or provide multiple "constructors". We'll keep it simple for this example.
type ParseError = (parseError ∷ Unit)

-- | The type is extremely similar to `BasicError`.
type BasicError' e =
  Variant
    ( unAuthorized :: Unit
    , serverError  :: Unit
    | e
    )

-- | We get to define as many as these as we need, in case some of the API's we use are
-- | (ab)using HTTP response codes to signal different kinds of errors.
mapBasicError :: StatusCode -> BasicError' ()
mapBasicError (StatusCode n)
  | n == 401  = inj _unAuthorized unit
  | otherwise = inj _serverError  unit

-- | Helper for defining a parse error.
parseError :: Variant ParseError
parseError = inj _parseError unit

-- | This is slightly more difficult because we need to pass the two helper functions
-- | to `decodeWithError`, however we gain some power: we can treat error codes
-- | differently when needed.
getFile' :: forall eff. String -> Aff (ajax :: AJAX | eff) (Either (BasicError' ParseError) String)
getFile' s =
  runAffjaxWithError mapBasicError (const parseError) $ defaultRequest
    { url = "simpleAPI/" <> s
    , method = Left GET
    }

-- | And adding NotFound...
_notFound     = SProxy :: SProxy "notFound"

-- | Same with `notFound` on top.
type SomeError' e = BasicError' (notFound ∷ Unit | e)

-- | We need a map for this as well, and we can re-use the "sub"-map just like we did
-- | with the class instance.
mapNotFound :: StatusCode -> SomeError' ()
mapNotFound sc@(StatusCode n)
  | n == 404  = inj _notFound unit
  | otherwise = expand $ mapBasicError sc

-- | The new endpoint in Variant format.
getFilePlus' :: forall eff. String -> Aff (ajax :: AJAX | eff) (Either (SomeError' ParseError) String)
getFilePlus' s =
  runAffjaxWithError mapNotFound (const parseError) $ defaultRequest
    { url = s
    , method = Left GET
    }

main :: forall e. Eff (ajax :: AJAX, console :: CONSOLE | e) Unit
main = do
  launchAff_ $ do
    res <- getFilePlus "data.json"
    let str = case res of
                Left err -> case err of
                  NotFound -> "not found"
                  SomeBasicError Unauthorized -> "unauthorized"
                  SomeBasicError ServerError -> "server error"
                  SomeBasicError ParseError -> "parse error"
                Right x -> x
    liftEff $ log ("S." <> str)
    res' <- getFilePlus' "data.json"
    let str' = case res' of
                Left err ->
                  case_
                    # on _notFound (const "not found")
                    # on _unAuthorized (const "unauthorized")
                    # on _serverError (const "server error")
                    # on _parseError (const "parse error")
                    $ err
                Right x -> x
    liftEff $ log ("V." <> str')

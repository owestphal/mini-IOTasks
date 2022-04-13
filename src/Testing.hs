{-# LANGUAGE RecordWildCards #-}
module Testing where

import IOrep (IOrep, Line, runProgram)
import Specification
import Constraints
import Trace
import Z3

import Control.Monad (forM, replicateM, filterM)
import Data.Maybe
import Data.List (nub)

data TestConfig = TestConfig { depth :: Int, sizeBound :: Integer, testsPerPath :: Int }

defaultConfig :: TestConfig
defaultConfig = TestConfig 25 100 5

fulfillsOld :: TestConfig -> IOrep () -> Specification -> IO Outcome
fulfillsOld TestConfig{..} prog spec  = do
  let ps = paths depth $ constraintTree spec
  satPaths <- filterM isSatPath ps
  nestedIs <- forM satPaths $ \p -> do
    ms <- replicateM testsPerPath $ findPathInput p sizeBound
    pure $ catMaybes ms
  let is = map (map show) $ nub $ concat nestedIs
  putStrLn $ unwords ["generated", show (length is),"unique inputs covering", show (length satPaths),"satisfiable paths ("++ show (length ps),"paths with max. depth",show depth,"in total)"]
  pure . fst $ runTests prog spec is

fulfills :: TestConfig -> IOrep () -> Specification -> IO Outcome
fulfills TestConfig{..} prog spec = do
  let ps = paths depth $ constraintTree spec
  (out,satPaths,nInputs) <- testPaths ps (0,0)
  putStrLn $ unwords
    ["generated", show nInputs,"inputs covering", show satPaths,"satisfiable paths ("++ show (length ps),"paths with max. depth",show depth,"in total)"]
  pure out

  where
    testPaths :: [Path] -> (Int,Int) -> IO (Outcome,Int,Int)
    testPaths [] (m,n) = pure (Success,m,n)
    testPaths (p:ps) (m,n) = do
      sat <- isSatPath p
      if sat
        then do
          (out,k) <- testPath p 0
          case out of
            Success -> testPaths ps (m+1,n+k)
            failure -> pure (failure,m+1,n+k)
        else testPaths ps (m,n)
    testPath :: Path -> Int -> IO (Outcome,Int)
    testPath _ n | n >= testsPerPath = pure (Success,n)
    testPath p n = do
      nextInput <- map show . fromJust <$> findPathInput p sizeBound -- check usage of fromJust
      let
        specTrace = runSpecification nextInput spec
        progTrace = runProgram nextInput prog
      case specTrace `covers` progTrace of
        MatchSuccessfull -> testPath p (n+1)
        failure -> pure (Failure nextInput failure,n+1)

type Inputs = [Line]

data Outcome = Success | Failure Inputs MatchResult
  deriving Eq

instance Show Outcome where
  show Success = "Success"
  show (Failure is r) = unlines ["Failure","  "++show is, "  "++show r]

runTests :: IOrep () -> Specification -> [Inputs] -> (Outcome,Int)
runTests = go 0 where
  go n _ _ [] = (Success,n)
  go n prog spec (i:is) =
    let
      specTrace = runSpecification i spec
      progTrace = runProgram i prog
    in case specTrace `covers` progTrace of
      MatchSuccessfull -> go (n+1) prog spec is
      failure -> (Failure i failure,n)

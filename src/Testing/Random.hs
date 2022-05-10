{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE LambdaCase #-}
module Testing.Random where

import Testing hiding (taskCheck, taskCheckWith, Args, stdArgs)

import Data.Map as Map hiding (foldr)
import Data.Set as Set hiding (foldr)
import Control.Monad (when)

import IOrep (IOrep, runProgram)
import Specification
import Trace
import Term
import OutputPattern

import Test.QuickCheck (Gen, vectorOf, generate, frequency)
import ValueSet

taskCheck :: IOrep () -> Specification -> IO Outcome
taskCheck = taskCheckWith stdArgs

data Args
  = Args
  { maxPathDepth :: Int
  , valueSize :: Integer
  , maxSuccess :: Int
  , maxNegative :: Int
  , verbose :: Bool
  }

stdArgs :: Args
stdArgs = Args
  { maxPathDepth = 25
  , valueSize = 100
  , maxSuccess = 100
  , maxNegative = 5
  , verbose = True
  }

taskCheckWith :: Args -> IOrep () -> Specification -> IO Outcome
taskCheckWith Args{..} prog spec  = do
  is <- generate $ vectorOf maxSuccess $ genInput spec maxPathDepth valueSize maxNegative
  let (outcome, n) = runTests prog spec is
  when verbose $ putStrLn $ unwords ["passed", show n,"tests"]
  pure outcome

genInput :: Specification -> Int -> Integer -> Int -> Gen Inputs
genInput s depth bound maxNeg = do
  t <- genTrace s depth bound maxNeg
  if isTerminating t
    then pure $ inputSequence t
    else genInput s depth bound maxNeg -- repeat sampling until a terminating trace is found

genTrace :: Specification -> Int -> Integer -> Int -> Gen Trace
genTrace spec depth bound maxNeg =
  semM
    (\(e,d,n) x vs mode ->
      (if d <= (0 :: Int) then pure NoRec
      else do
        frequency $
            (5, valueOf vs bound >>= (\i -> pure $ RecSub i (Map.update (\xs -> Just $ i:xs) x e,d-1,n)))
          : [(1, valueOf (complement vs) bound >>= (\i -> pure $ RecSame i (e,d-1,n+1))) | mode == UntilValid && n < maxNeg]
    ))
    (pure . \case
      NoRec -> OutOfInputs
      RecSub i t' -> do
        foldr ProgRead t' (show i ++ "\n")
      RecSame i t' -> do
        foldr ProgRead t' (show i ++ "\n")
      RecBoth{} -> error "genTrace: impossible"
    )
    (\(e,_,_) o ts t' -> ProgWrite o (Set.map (evalPattern $ Map.toList e) ts) <$> t')
    (\(e,_,_) c l r -> if eval c $ Map.toList e then l else r)
    (pure Terminate)
    (Map.fromList ((,[]) <$> vars spec),depth,0)
    spec

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

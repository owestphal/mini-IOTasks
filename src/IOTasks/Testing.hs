{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE LambdaCase #-}
module IOTasks.Testing where

import IOTasks.IOrep (IOrep, Line, runProgram)
import IOTasks.Specification
import IOTasks.Constraints
import IOTasks.Trace
import IOTasks.Z3
import IOTasks.Overflow
import IOTasks.Output

import Control.Concurrent.STM
import Control.Monad (when, forM, replicateM)

import Data.Maybe (catMaybes)
import Data.List (sortOn)
import Data.Functor (void)
import Data.Bifunctor (first)

import Text.PrettyPrint hiding ((<>))
import Control.Concurrent (forkIO, killThread)
import Control.Exception (finally)
import System.IO

taskCheck :: IOrep () -> Specification -> IO ()
taskCheck = taskCheckWith stdArgs

data Args
  = Args
  { maxIterationUnfold :: Int -- maximum sum of iteration unfoldings when searching for satisfiable paths
  , valueSize :: Integer -- size of randomly generated input candidates (the solver might find bigger solutions)
  , solverTimeout :: Int -- solver timeout in miliseconds
  , maxTimeouts :: Int -- maximum number of solver timeouts before giving up
  , maxSuccessPerPath :: Int -- number of tests generated per path
  , maxNegative :: Int -- maximum number of negative inputs per path
  , verbose :: Bool -- print extra information
  , simplifyFeedback :: Bool -- cleanup feedback for educational use
  , checkOverflows :: Bool -- check that intermediate results do not cause Int overflows, including (parts of OutputTerms when possible) (best-effort, no gurantees on completness)
  , solverMaxSeqLength :: Int -- maximum length of Sequence values in the the backend solver (affects string length as well). Smaller values may speed up test case generation, at the risk of not finding some satisfiable paths
  }

stdArgs :: Args
stdArgs = Args
  { maxIterationUnfold = 25
  , valueSize = 100
  , solverTimeout = 1000
  , maxTimeouts = 3
  , maxSuccessPerPath = 5
  , maxNegative = 5
  , verbose = True
  , simplifyFeedback = False
  , checkOverflows = False
  , solverMaxSeqLength = 25
  }

taskCheckWith :: Args -> IOrep () -> Specification -> IO ()
taskCheckWith args p s = void $ taskCheckWithOutcome args p s

taskCheckOutcome :: IOrep () -> Specification -> IO Outcome
taskCheckOutcome = taskCheckWithOutcome stdArgs

type SatPaths = Int
type NumberOfInputs = Int
type Timeouts = Int
type Overflows = Int
type TestsRun = Int

taskCheckWithOutcome :: Args -> IOrep () -> Specification -> IO Outcome
taskCheckWithOutcome Args{..} prog spec = do
  output <- newOutput stdout
  q <- atomically newTQueue
  nVar <- newTVarIO Nothing
  thrdID <- forkIO $ satPaths nVar solverTimeout (constraintTree maxNegative spec) maxIterationUnfold solverMaxSeqLength checkOverflows q
  (coreOut,satPaths,nInputs,timeouts,overflows) <- testPaths output nVar q (0,0,0,0) Nothing `finally` killThread thrdID

  let out = Outcome coreOut (if overflows == 0 then NoHints else OverflowHint overflows)
  --
  when verbose $ do
    putLnP output $ unwords
      ["generated", show nInputs,"inputs covering", show satPaths, "satisfiable paths"]
    when (timeouts > 0) $
      putLnP output $ unwords ["---",show timeouts, "paths timed out"]
  --
  printP output $ (if simplifyFeedback then pPrintOutcomeSimple else pPrintOutcome) out
  pure out

  where
    testPaths :: Output -> TVar (Maybe Int) -> TQueue (Maybe Path) -> (SatPaths,NumberOfInputs,Timeouts,Overflows) -> Maybe CoreOutcome -> IO (CoreOutcome,SatPaths,NumberOfInputs,Timeouts,Overflows)
    testPaths _ _ _ (m,n,t,o) (Just failure) | t > maxTimeouts = pure (failure,m,n,t,o)
    testPaths _ _ _ (m,n,t,o) Nothing | t > maxTimeouts = pure (GaveUp,m,n,t,o)
    testPaths output nVar q (m,n,t,o) mFailure = do
      p <- atomically $ readTQueue q
      currentMaxPathLength <- readTVarIO nVar
      case p of
        Nothing -> case mFailure of -- no more paths
           (Just failure) -> pure (failure,m,n,t,o)
           Nothing -> pure (Success n,m,n,t,o)
        Just p
          | maybe False (pathDepth p >) currentMaxPathLength -> testPaths output nVar q (m,n,t,o) mFailure
          | otherwise -> do
          res <- isSatPath solverTimeout p solverMaxSeqLength checkOverflows
          if res == SAT -- TODO: does not account for timeouts yet
            then do
              (out,k,o') <- testPath output p 0 n 0
              case out of
                PathSuccess -> do
                  testPaths output nVar q (m+1,n+k,t,o+o') mFailure
                PathFailure i et at r ->
                  if maybe True (\case {Failure j _ _ _ -> length i < length j; _ -> error "impossible"}) mFailure -- there might be paths in the queue that are longer than a found counterexample
                    then do
                      atomically $ writeTVar nVar (Just $ length i - 1)
                      testPaths output nVar q (m+1,n+k,t,o+o') (Just $ Failure i et at r)
                    else
                      testPaths output nVar q (m+1,n+k,t,o+o') mFailure
                PathTimeout
                  | k > 0 -> testPaths output nVar q (m+1,n+k,t,o+o') mFailure
                  | otherwise -> testPaths output nVar q (m,n,t+1,o+o') mFailure
            else testPaths output nVar q (m,n,t,o) mFailure
    testPath :: Output -> Path -> TestsRun -> NumberOfInputs -> Overflows -> IO (PathOutcome,TestsRun,Overflows)
    testPath _ _ n _ o | n >= maxSuccessPerPath = pure (PathSuccess,n,o)
    testPath output p n nOtherTests o = do
      mNextInput <- findPathInput solverTimeout p valueSize solverMaxSeqLength checkOverflows
      case mNextInput of
        Nothing -> pure (PathTimeout,n,o) -- should (only?) be the case if solving times out
        Just nextInput  -> do
          when verbose (putT output (concat ["(",show (n+nOtherTests)," tests)"]) >> oFlush output)
          let
            (specTrace,warn) = first normalizedTrace $ runSpecification nextInput spec
            progTrace = runProgram nextInput prog
            o' = if warn == OverflowWarning then o+1 else o
          when (verbose && warn == OverflowWarning) $ putLnP output "Overflow of Int range detected."
          case specTrace `covers` progTrace of
            MatchSuccessfull -> testPath output p (n+1) nOtherTests o'
            failure -> do
              when verbose $ putLnP output $ unwords ["found counterexample of length",show $ length nextInput]
              pure (PathFailure nextInput specTrace progTrace failure,n+1,o')

type Inputs = [Line]
type ExpectedRun = NTrace
type ActualRun = NTrace

data Outcome = Outcome CoreOutcome OutcomeHints
  deriving (Eq, Show)

data CoreOutcome = Success Int | Failure Inputs ExpectedRun ActualRun MatchResult | GaveUp
  deriving (Eq, Show)

data OutcomeHints = NoHints | OverflowHint Int
  deriving (Eq, Show)

isSuccess :: Outcome -> Bool
isSuccess (Outcome Success{} _) = True
isSuccess _ = False

overflowWarnings :: Outcome -> Int
overflowWarnings (Outcome _ NoHints) = 0
overflowWarnings (Outcome _ (OverflowHint n)) = n

data PathOutcome = PathSuccess | PathTimeout | PathFailure Inputs ExpectedRun ActualRun MatchResult
  deriving (Eq,Show)

pPrintOutcome :: Outcome -> Doc
pPrintOutcome (Outcome core hints) = pPrintOutcomeHints hints $+$ pPrintCoreOutcome False core

pPrintOutcomeSimple :: Outcome -> Doc
pPrintOutcomeSimple (Outcome core hints) = pPrintOutcomeHints hints $+$ pPrintCoreOutcome True core

pPrintCoreOutcome :: Bool -> CoreOutcome -> Doc
pPrintCoreOutcome _ (Success n) = text $ unwords ["+++ OK, passed",show n,"tests."]
pPrintCoreOutcome _ GaveUp = text "*** Gave up!"
pPrintCoreOutcome simple (Failure is et at r) = vcat
  [ text "*** Failure"
  , text ("Input sequence "++ pPrintInputs is)
  , text ("Expected run: " ++ printTrace et)
  , text ("Actual run: " ++ printTrace at)
  , text "Error:"
  , nest 2 (printResult r)
  ]
  where
    (printResult, printTrace)
      | simple = (pPrintMatchResultSimple,pPrintTraceSimple)
      | otherwise = (pPrintMatchResult,pPrintTrace)

pPrintInputs :: Inputs -> String
pPrintInputs = unwords . map ('?':)

pPrintOutcomeHints :: OutcomeHints -> Doc
pPrintOutcomeHints NoHints = mempty
pPrintOutcomeHints (OverflowHint n) = text $ unwords [show n,"overflows of Int range where detected during testing"]

-- static test suite generation
taskCheckOn :: [Inputs] -> IOrep () -> Specification -> Outcome
taskCheckOn i p s = uncurry Outcome (go 0 0 i p s) where
  go n o [] _ _ = (Success n, overflowHint o)
  go n o (i:is) prog spec =
    let
      (specTrace,warn) = first normalizedTrace $ runSpecification i spec
      progTrace = runProgram i prog
      o' = if warn == OverflowWarning then o+1 else o
    in case specTrace `covers` progTrace of
      MatchSuccessfull -> go (n+1) o' is prog spec
      failure -> (Failure i specTrace progTrace failure, overflowHint o')

  overflowHint 0 = NoHints
  overflowHint n = OverflowHint n

generateStaticTestSuite :: Args -> Specification -> IO [Inputs]
generateStaticTestSuite Args{..} spec =
  let ps = sortOn pathDepth $ paths maxIterationUnfold $ constraintTree maxNegative spec
  in concat <$> forM ps (\p -> catMaybes <$> replicateM maxSuccessPerPath (findPathInput solverTimeout p valueSize solverMaxSeqLength checkOverflows))

module Test.IOTasks (
  -- * Specifications
  Specification, runSpecification, runSpecification', accept,
  readInput,
  writeOutput, writeOptionalOutput, optionalTextOutput, branch, tillExit, exit, nop, until, while,
  InputMode(..), ValueSet(..),
  ints, nats, str,
  OutputPattern(..),
  Var, Varname, var, intVar, stringVar,
  pPrintSpecification,
  -- * Terms
  Term,
  OutputTerm,
  Arithmetic(..),
  Compare(..),
  Logic(..),
  BasicLists(..), ComplexLists(..),
  Sets(..),
  Accessor(..),
  as,
  OverflowType,
  -- * Programs
  MonadTeletype(..),
  IOrep, runProgram, Line,
  Trace, covers,
  -- * Testing
  taskCheck, taskCheckWith, taskCheckOutcome, taskCheckWithOutcome, Args(..), stdArgs,
  Outcome(..), CoreOutcome(..), OutcomeHints(..), isSuccess, isFailure, overflowWarnings,
  pPrintOutcome, pPrintOutcomeSimple,
  -- ** pre-computed test suites
  generateStaticTestSuite, taskCheckOn,
  -- * Interpreter
  interpret,
  ) where

import Prelude hiding (until)

import Test.IOTasks.Specification
import Test.IOTasks.MonadTeletype
import Test.IOTasks.IOrep
import Test.IOTasks.Term
import Test.IOTasks.Terms
import Test.IOTasks.ValueSet
import Test.IOTasks.OutputPattern
import Test.IOTasks.OutputTerm
import Test.IOTasks.Testing
import Test.IOTasks.Interpreter
import Test.IOTasks.Trace
import Test.IOTasks.Overflow (OverflowType)

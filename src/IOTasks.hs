module IOTasks
  ( Specification, runSpecification
  , readInput, writeOutput, writeOptionalOutput, branch, until
  , InputMode(..)
  , MonadTeletype(..)
  , IOrep, runProgram, Line
  , Trace, (>:)
  , Term(..)
  , ValueSet(..)
  , OutputPattern(..), PatternType(..)
  , OutputTerm, current, all, (+#), (-#), (*#), length', sum'
  , taskCheck, taskCheckWith, taskCheckOutcome, taskCheckWithOutcome, Args(..), stdArgs
  , generateStaticTestSuite, taskCheckOn
  , interpret
  ) where

import Prelude hiding (until,all)

import IOTasks.Specification
import IOTasks.MonadTeletype
import IOTasks.IOrep
import IOTasks.Term
import IOTasks.ValueSet
import IOTasks.OutputPattern
import IOTasks.OutputTerm
import IOTasks.Testing
import IOTasks.Interpreter
import IOTasks.Trace

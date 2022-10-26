{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
module IOTasks.Constraints where

import IOTasks.ValueSet
import IOTasks.Term (Term, printIndexedTerm, castTerm, subTerms)
import IOTasks.Terms (Var, not', varname)
import IOTasks.Specification
import IOTasks.OutputPattern (valueTerms)
import IOTasks.OutputTerm (transparentSubterms, withSomeOutputTerm)

import Data.List (intersperse)
import qualified Data.Map as Map
import Data.Map (Map)
import qualified Data.Set as Set (toList)
import Data.Maybe (catMaybes, mapMaybe)
import Data.Tuple.Extra (fst3)
import Data.Typeable

data Constraint (t :: ConstraintType) where
  InputConstraint :: Typeable v => (Var, Int) -> ValueSet v -> Constraint 'Input
  ConditionConstraint :: Term Bool -> Map Var (Int, [Int]) -> Constraint 'Condition
  OverflowConstraints :: [Term Integer] -> Map Var (Int, [Int]) -> Constraint 'Overflow

data ConstraintType = Input | Condition | Overflow

data SomeConstraint where
  SomeConstraint :: Constraint t -> SomeConstraint

data ConstraintTree where
  Choice :: ConstraintTree -> ConstraintTree -> ConstraintTree
  Assert :: (Constraint t) -> ConstraintTree -> ConstraintTree
  Empty :: ConstraintTree

constraintTree :: Int -> Specification -> ConstraintTree
constraintTree negMax =
  sem
    (\(n,e,k) x vs mode ->
      let
        e' = inc x k e
        p = (InputConstraint(x, ix x e') vs
            ,InputConstraint(x, ix x e') (complement vs)
            , mode == Abort && n < negMax)
      in case mode of
          AssumeValid -> RecSub p (n,e',k+1)
          UntilValid
            | n < negMax -> RecBoth p (n,e',k) (n+1,e',k+1)
            | otherwise -> RecSub p (n,e',k+1)
          Abort -> RecSub p (n,e',k)
    )
    (\case
      RecSub (vsP,_, False) s' -> Assert vsP s'
      RecSub (vsP,vsN, True) s' -> Choice
        (Assert vsN Empty)
        (Assert vsP s')
      RecBoth (vsP,vsN,_) s' s -> Choice
        (Assert vsN s)
        (Assert vsP s')
      NoRec _ -> error "constraintTree: impossible"
      RecSame{} -> error "constraintTree: impossible"
    )
    (\(_,e,_) _ ps t -> Assert (OverflowConstraints (catMaybes $ [ castTerm @Integer t | p <- Set.toList ps, vt <- valueTerms p, t <- withSomeOutputTerm vt transparentSubterms]) e) t)
    (\(_,e,_) c l r -> Assert (OverflowConstraints (mapMaybe (castTerm @Integer) $ subTerms c) e) $ Choice (Assert (ConditionConstraint c e) l) (Assert (ConditionConstraint (not' c) e) r))
    Empty
    (0,Map.empty,1)

ix :: Var -> Map Var (Int,a) -> Int
ix x m = maybe 0 fst (Map.lookup x m)

inc :: Var -> Int -> Map Var (Int,[Int]) -> Map Var (Int,[Int])
inc x k m
  | x `elem` Map.keys m = Map.update (\(c,ks) -> Just (c + 1,k:ks)) x m
  | otherwise = Map.insert x (1,[k]) m

type Path = [SomeConstraint]

paths :: Int -> ConstraintTree -> [Path]
paths _ Empty = [[]]
paths n _ | n < 0 = []
paths n (Choice lt rt) = mergePaths (paths n lt) (paths n rt)
paths n (Assert c@InputConstraint{} t) = (SomeConstraint c:) <$> paths (n-1) t
paths n (Assert c@ConditionConstraint{} t) = (SomeConstraint c:) <$> paths n t
paths n (Assert c@OverflowConstraints{} t) = (SomeConstraint c:) <$> paths n t

mergePaths :: [Path] -> [Path] -> [Path]
mergePaths xs [] = xs
mergePaths [] ys = ys
mergePaths (x:xs) (y:ys) = x:y:mergePaths xs ys

pathDepth :: Path -> Int
pathDepth =  length . fst3 . partitionPath

partitionPath :: Path -> ([Constraint 'Input],[Constraint 'Condition],[Constraint 'Overflow])
partitionPath = foldMap phi where
  phi :: SomeConstraint -> ([Constraint 'Input],[Constraint 'Condition],[Constraint 'Overflow])
  phi (SomeConstraint c@InputConstraint{}) = ([c],mempty,mempty)
  phi (SomeConstraint c@ConditionConstraint{}) = (mempty,[c],mempty)
  phi (SomeConstraint c@OverflowConstraints{}) = (mempty,mempty,[c])

printPath :: Path -> String
printPath = unlines . intersperse " |" . map printSomeConstraint

printSomeConstraint :: SomeConstraint -> String
printSomeConstraint (SomeConstraint c) = printConstraint c

printConstraint :: Constraint t -> String
printConstraint (InputConstraint (x,i) vs) = concat [varname x,"_",show i," : ",printValueSet vs]
printConstraint (ConditionConstraint t m) = printIndexedTerm t m
printConstraint (OverflowConstraints _ _) = "**some overflow checks**"

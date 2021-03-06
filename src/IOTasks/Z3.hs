{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TupleSections #-}
module IOTasks.Z3 where

import IOTasks.Constraints
import IOTasks.ValueSet
import IOTasks.Term
import IOTasks.Terms (Varname, VarExp(..))

import Z3.Monad

import Test.QuickCheck (generate)
import Control.Monad (forM, forM_)
import Control.Monad.IO.Class (liftIO)
import Data.Maybe (catMaybes, fromMaybe, isJust, mapMaybe)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.List (intercalate, sortOn)
import Data.Tuple.Extra (thd3)

type Timeout = Int

findPathInput :: Timeout -> Path -> Integer -> IO (Maybe [Integer])
findPathInput t p bound = do
  evalZ3With Nothing (stdOpts +? opt "timeout" (show t)) $ pathScript p $ WithSoft bound

isSatPath :: Timeout -> Path -> IO Bool
isSatPath t p = do
  isJust <$> evalZ3With Nothing (stdOpts +? opt "timeout" (show t)) (pathScript p WithoutSoft)

data ScriptMode = WithSoft Integer | WithoutSoft

pathScript :: Path -> ScriptMode -> Z3 (Maybe [Integer])
pathScript path mode = do
  let (tyConstr,predConstr) = partitionPath path
  vars <- forM tyConstr $
    \(InputConstraint (x,i) vs) -> do
      var <- mkFreshIntVar $ x ++ show i
      constraint <- z3ValueSetConstraint vs var
      optimizeAssert constraint
      pure (((x,i),var),vs)
  forM_ predConstr $
    \(ConditionConstraint t e) ->
      optimizeAssert =<< z3Predicate t e (map fst vars)
  case mode of
    WithSoft bound -> do
      vs <- liftIO $ forM vars $ \((_,ast),vs) -> do {v <- generate $ valueOf vs bound; pure (ast,v)}
      def <- mkStringSymbol "default"
      forM_ vs $ \(ast,v) -> do
        eq <- mkEq ast =<< mkInteger v
        optimizeAssertSoft eq "1" def -- soft assert with weight 1 and id "default"
    WithoutSoft -> pure ()
  -- str <- optimizeToString
  -- liftIO $ print str
  result <- optimizeCheck []
  case result of
    Sat -> do
      model <- optimizeGetModel
      Just . catMaybes <$> mapM ((evalInt model . snd) . fst) vars
    _ -> do
      _str <- optimizeToString
      -- liftIO $ print str
      pure Nothing

z3Predicate :: Term a -> Map Varname (Int,[Int]) -> [((Varname, Int), AST)] -> Z3 AST
z3Predicate (x :+: y) e vars = binRec e vars (\a b -> mkAdd [a,b]) x y
z3Predicate (x :-: y) e vars = binRec e vars (\a b -> mkSub [a,b]) x y
z3Predicate (x :*: y) e vars = binRec e vars (\a b -> mkMul [a,b]) x y
z3Predicate (x :==: y) e vars = binRec e vars mkEq x y
z3Predicate (x :>: y) e vars = binRec e vars mkGt x y
z3Predicate (x :>=: y) e vars = binRec e vars mkGe x y
z3Predicate (x :<: y) e vars = binRec e vars mkLt x y
z3Predicate (x :<=: y) e vars = binRec e vars mkLe x y
z3Predicate (Not x) e vars = mkNot =<< z3Predicate x e vars
z3Predicate (x :&&: y) e vars = binRec e vars (\a b -> mkAnd [a,b]) x y
z3Predicate (x :||: y) e vars = binRec e vars (\a b -> mkOr [a,b]) x y
z3Predicate (Length (All x)) e _ = mkIntNum $ length $ weaveVariables x e
z3Predicate (Sum (All x)) e vars = mkAdd $ lookupList (weaveVariables x e) vars
z3Predicate (Product (All x)) e vars = mkMul $ lookupList (weaveVariables x e) vars
z3Predicate (Current x) e vars = pure $ fromMaybe (error $ "unknown variable(s) {" ++ intercalate "," (toVarList x) ++ "}" ++ show e ++ show vars) $ (`lookup` vars) . last $ weaveVariables x e
z3Predicate (All _x) _e _vars = error "generic list"
z3Predicate (IntLit n) _ _ = mkIntNum n

-- helper for binary recursive case
binRec :: Map Varname (Int,[Int]) -> [((Varname,Int),AST)] -> (AST -> AST -> Z3 AST) -> Term a -> Term a -> Z3 AST
binRec e vs f x y = do
  xP <- z3Predicate x e vs
  yP <- z3Predicate y e vs
  f xP yP

weaveVariables :: VarExp a => a -> Map Varname (Int,[Int]) -> [(Varname,Int)]
weaveVariables vs e =
    map (\(x,y,_) -> (x,y))
  . sortOn thd3
  . concatMap (\(x,(i,ks)) -> [(x,j,k) | (j,k) <- zip [i,i-1..1] ks ])
  . mapMaybe (\v -> (v,) <$> Map.lookup v e)
  $ toVarList vs

lookupList :: Eq a => [a] -> [(a, b)] -> [b]
lookupList vs vars = mapMaybe (`lookup` vars) vs

z3ValueSetConstraint :: ValueSet -> AST -> Z3 AST
z3ValueSetConstraint (Union x y) xVar = do
  cx <- z3ValueSetConstraint x xVar
  cy <- z3ValueSetConstraint y xVar
  mkOr [cx,cy]
z3ValueSetConstraint (Intersection x y) xVar = do
  cx <- z3ValueSetConstraint x xVar
  cy <- z3ValueSetConstraint y xVar
  mkAnd [cx,cy]
z3ValueSetConstraint (GreaterThan n) xVar = mkIntNum n >>= mkGt xVar
z3ValueSetConstraint (LessThen n) xVar = mkIntNum n >>= mkLt xVar
z3ValueSetConstraint (Eq n) xVar = mkIntNum n >>= mkEq xVar
z3ValueSetConstraint Every _ = mkTrue
z3ValueSetConstraint None _ = mkFalse

{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ExistentialQuantification #-}
module SpecificationGenerator where

import IOTasks
import IOTasks.Specification

import Test.QuickCheck
import Type.Reflection

ints :: ValueSet Integer
ints = Every

nats :: ValueSet Integer
nats = Eq 0 `Union` GreaterThan 0

instance Arbitrary Specification where
  arbitrary = specGen
  shrink = shrinkSpec

instance Show Specification where
  show = (++ "\n--\n") . show . pPrintSpecification

specGen :: Gen Specification
specGen = simpleSpec

shrinkSpec :: Specification -> [Specification]
shrinkSpec (ReadInput _ _ _ s) = []
shrinkSpec (WriteOutput _ _ s) = [s]
shrinkSpec (Branch c s1 s2 s) = [s1, s2, s, Branch c s1 s2 nop]
shrinkSpec Nop = []
shrinkSpec E = []
shrinkSpec (TillE s s') = [dropE s, s']
  where
    dropE :: Specification -> Specification
    dropE (ReadInput x ty m s') = ReadInput x ty m (dropE s')
    dropE (WriteOutput opt os s') = WriteOutput opt os (dropE s')
    dropE (Branch c s1 s2 s') = Branch c (dropE s1) (dropE s2) (dropE s')
    dropE Nop = Nop
    dropE (TillE s s') = TillE s (dropE s')
    dropE E = Nop

-- generator for simple specifications
simpleSpec :: Gen Specification
simpleSpec = do
  i <- input [(intVar "n",ints,AssumeValid)]
  l <- loop [(intVar "xs",ints,AssumeValid)] (progressCondition [(intVar "xs",ints)] [intVar "n"])
  p <- outputOneof (intTerm [intVar "xs", intVar "y"] [intVar "n"])
  pure $ i <> l <> p

-- generator for standalone loop bodies
loopBodyGen :: Gen (Specification,Specification)
loopBodyGen = do
  s <- loopBody [(intVar "xs",ints,AssumeValid)] (progressCondition [(intVar "xs",ints)] [intVar "n"])
  return (s, readInput (intVar "n") nats AssumeValid)

-- basic generators
input :: (Typeable a,Read a, Show a) => [(Var,ValueSet a,InputMode)] -> Gen Specification
input xs = do
  (x,vs,m) <- elements xs
  pure $ readInput x vs m

someInputsWithHole ::  (Typeable a,Read a, Show a) =>  [(Var,ValueSet a,InputMode)] -> Int -> Gen (Specification -> Specification)
someInputsWithHole xs nMax = do
  n <- choose (1,nMax)
  p <- choose (0,n-1)
  (is1,is2) <- splitAt p <$> vectorOf n (input xs)
  pure $ \s -> mconcat $ is1 ++ [s] ++ is2

outputOneof :: OverflowType a => Gen (OutputTerm a) -> Gen Specification
outputOneof = outputOneof' False

optionalOutputOneof :: OverflowType a => Gen (OutputTerm a) -> Gen Specification
optionalOutputOneof = outputOneof' True

outputOneof' :: OverflowType a => Bool -> Gen (OutputTerm a) -> Gen Specification
outputOneof' b ts = do
  t <- ts
  pure $ (if b then writeOptionalOutput else writeOutput) [Value t]

-- branch free sequence of inputs and outputs
linearSpec :: (Typeable a, Read a, Show a) => [(Var,ValueSet a,InputMode)] -> [(Var,ValueSet a,InputMode)] -> Gen (Specification, [Var])
linearSpec lists xs = sized $ \n -> do
  is <- ($ nop) <$> someInputsWithHole (lists ++ xs) (n `div` 2)
  let vs = vars is
  os <- resize (n `div` 2) $ listOf1 $ outputOneof (intTerm vs vs)
  let spec = is <> mconcat os
  return (spec,vars spec)

-- simple loop
loop :: (Typeable a,Read a, Show a) => [(Var,ValueSet a,InputMode)] -> Gen Condition -> Gen Specification
loop xs loopCondition = tillExit <$> loopBody xs loopCondition

loopBody :: (Typeable a,Read a, Show a) => [(Var,ValueSet a,InputMode)] -> Gen Condition -> Gen Specification
loopBody xs loopCondition = do
  cond <- loopCondition
  let progress = case cond of  Condition _ (xp,vs) -> readInput xp vs AssumeValid
  s1 <- someInputsWithHole xs 2
  let s1' = s1 progress
  oneof
    [ pure $ branch (condTerm cond) exit s1'
    , pure $ branch (not' $ condTerm cond) s1' exit
    ]

data Condition = forall a. (Typeable a, Read a, Show a) => Condition { condTerm :: Term Bool, progressInfo :: (Var,ValueSet a) }

-- generates a numeric condition of the form
-- f xs `comp` n
-- that contains every variable at most once
progressCondition :: (Typeable a, Read a, Show a) => [(Var,ValueSet a)] -> [Var] -> Gen Condition
progressCondition lists nums = do
  comp <- elements [(.>.)]
  n <- oneof [as @Integer . currentValue <$> elements nums, intLit <$> choose (0,10)]
  (xs,vs) <- elements lists
  f <- elements [length']
  return $ Condition (f (as @[Integer] $ allValues xs) `comp` n) (xs,vs)

-- simple terms
intTerm :: [Var] -> [Var] -> Gen (OutputTerm Integer)
intTerm lists xs =
  oneof $ concat
    [ [ unary  | not $ null lists ]
    , [ var    | not $ null xs]
    , [ binary | not $ null xs]
    ]
  where
    var = do
      x <- elements xs
      pure $ currentValue x
    unary = do
      f <- elements [sum', length']
      x <- elements lists
      pure $ f $ allValues x
    binary = do
      f <- elements [(.+.), (.-.), (.*.)]
      x <- elements xs
      y <- elements xs
      pure $ f (currentValue x) (currentValue y)
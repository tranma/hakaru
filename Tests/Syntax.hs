{-# LANGUAGE MultiParamTypeClasses, TypeFamilies,
             FlexibleContexts, FlexibleInstances, DefaultSignatures,
             StandaloneDeriving, GeneralizedNewtypeDeriving,
             Rank2Types #-}
{-# OPTIONS -W #-}
import Prelude hiding (Real, repeat)
import Language.Hakaru.Syntax

-- pair1fst and pair1snd are equivalent
pair1fst :: (Mochastic repr) => repr (Measure (Bool, Real))
pair1fst =  beta 1 1 `bind` \bias ->
            bern bias `bind` \coin ->
            dirac (pair coin bias)
pair1snd :: (Mochastic repr) => repr (Measure (Bool, Real))
pair1snd =  bern (1/2) `bind` \coin ->
            if_ coin (beta 2 1) (beta 1 2) `bind` \bias ->
            dirac (pair coin bias)

-- pair2fst and pair2snd are equivalent
pair2fst :: (Mochastic repr) => repr (Measure ((Bool, Bool), Real))
pair2fst =  beta 1 1 `bind` \bias ->
            bern bias `bind` \coin1 ->
            bern bias `bind` \coin2 ->
            dirac (pair (pair coin1 coin2) bias)

pair2snd :: (Mochastic repr) => repr (Measure ((Bool, Bool), Real))
pair2snd =  bern (1/2) `bind` \coin1 ->
            bern (if_ coin1 (2/3) (1/3)) `bind` \coin2 ->
            beta (1 + f coin1 + f coin2)
                 (1 + g coin1 + g coin2) `bind` \bias ->
            dirac (pair (pair coin1 coin2) bias)
  where f b = if_ b 1 0
        g b = if_ b 0 1

type Cont repr a = forall w. (a -> repr (Measure w)) -> repr (Measure w)
{- This Cont monad is useful for generalizing pair2fst and pair2snd to an
 - arbitrary number of coin flips. The generalization would look liks this:

pair2'fst :: (Mochastic repr) => Int -> Cont repr ([repr Bool], repr Real)
-- REQUIREMENT: pair2fst = pair2'fst 2 (\([coin1,coin2],bias) -> dirac (pair (pair coin1 coin2) bias))
pair2'fst = undefined -- to be defined using replicateH

pair2'snd :: (Mochastic repr) => Int -> Cont repr ([repr Bool], repr Real)
pair2'snd = undefined -- to be defined using explicit recursion

replicateH :: (Mochastic repr) => Int -> repr (Measure a) -> Cont repr [repr a]
replicateH 0 _ k = k []
replicateH n m k = m `bind` \x -> replicateH (n-1) m (\xs -> k (x:xs))

twice :: (Mochastic repr) => repr (Measure a) -> Cont repr (repr a, repr a)
twice m k = m `bind` \x ->
            m `bind` \y ->
            k (x, y)
-}

-- pair3fst and pair3snd and pair3trd are equivalent
pair3fst, pair3snd, pair3trd :: (Mochastic repr) => repr Prob -> [repr Bool] -> repr (Measure ())
pair3fst bias [b1,b2,b3] =
  factor (if_ b1 bias (1-bias)) `bind_`
  factor (if_ b2 bias (1-bias)) `bind_`
  factor (if_ b3 bias (1-bias))
pair3snd bias [b1,b2,b3] =
  factor (if_ b1 bias (1-bias)
        * if_ b2 bias (1-bias)
        * if_ b3 bias (1-bias))
pair3trd bias [b1,b2,b3] =
  factor (pow_ bias     (if_ b1 1 0 + if_ b2 1 0 + if_ b3 1 0)
        * pow_ (1-bias) (if_ b1 0 1 + if_ b2 0 1 + if_ b3 0 1))

-- In Maple, should 'evaluate' to "\c -> 1/2*c(Unit)"
t1 :: (Mochastic repr) => repr (Measure ())
t1 = uniform 0 1 `bind` \x -> factor (unsafeProb x)

t2 :: Mochastic repr => repr (Measure Real)
t2 = beta 1 1

t3 :: Mochastic repr => repr (Measure Real)
t3 = normal 0 10

t4 :: Mochastic repr => repr (Measure (Real, Bool))
t4 = beta 1 1 `bind` \bias -> bern bias `bind` \coin -> dirac (pair bias coin)

-- t5 is "the same" as t1.
t5 :: Mochastic repr => repr (Measure ())
t5 = factor (1/2) `bind_` dirac unit

t6 :: Mochastic repr => repr (Measure Real)
t6 = dirac 5

t7 :: Mochastic repr => repr (Measure Real)
t7 = uniform 0 1 `bind` \x -> factor (unsafeProb (x+1)) `bind_` dirac (x*x)

-- For sampling efficiency (to keep importance weights at or close to 1),
-- t8 below should read back to uses of "normal", not uses of "lebesgue"
-- then "factor".  (For exact roundtripping, Maple "attributes" might help.)
t8 :: Mochastic repr => repr (Measure (Real, Real))
t8 = normal 0 10 `bind` \x -> normal x 20 `bind` \y -> dirac (pair x y)

t9 :: Mochastic repr => repr (Measure Real)
t9 = lebesgue `bind` \x -> factor (if_ (and_ [less 3 x, less x 7]) (1/2) 0) `bind_` dirac x

t10 :: Mochastic repr => repr (Measure ())
t10 = factor 0

t11 :: Mochastic repr => repr (Measure ())
t11 = factor 1

t12 :: Mochastic repr => repr (Measure ())
t12 = factor 2

t13 :: Mochastic repr => repr (Measure Real)
t13 = bern (3/5) `bind` \b -> dirac (if_ b 37 42)

t14 :: Mochastic repr => repr (Measure Real)
t14 = bern (3/5) `bind` \b ->
      if_ b t13 (bern (2/7) `bind` \b' ->
                 if_ b' (uniform 10 12) (uniform 14 16))

tester :: Expect Maple a -> String
tester t = runMaple (unExpect t) 0

-- this can sometimes be more convenient
tester2 :: (Expect' c ~ (b -> a)) => Maple b -> Expect Maple c -> String
tester2 c t = runMaple ((unExpect t) `app` c) 0

p1 :: String
p1 = tester2 (Maple (return "c")) t1

-- over time, this should be 'upgraded' to actually generate a proper
-- Maple test file
main :: IO ()
main = do
  putStrLn $ tester t1
  putStrLn $ tester t2
  putStrLn $ tester t3
  putStrLn $ tester t4
  putStrLn $ tester t5
  putStrLn $ tester t6
  putStrLn $ tester t7
  putStrLn $ tester t8
  putStrLn $ tester t9
  putStrLn $ tester t10
  putStrLn $ tester t11
  putStrLn $ tester t12
  putStrLn $ tester t13
  putStrLn $ tester t14
{-# LANGUAGE TypeOperators
           , KindSignatures
           , DataKinds
           , TypeFamilies
           , GADTs
           , FlexibleInstances
           , NoImplicitPrelude
           , ScopedTypeVariables
           , FlexibleContexts
           #-}

{-# OPTIONS_GHC -Wall -fwarn-tabs #-}
----------------------------------------------------------------
--                                                    2015.10.29
-- |
-- Module      :  Language.Hakaru.Syntax.Prelude
-- Copyright   :  Copyright (c) 2015 the Hakaru team
-- License     :  BSD3
-- Maintainer  :  wren@community.haskell.org
-- Stability   :  experimental
-- Portability :  GHC-only
--
-- A replacement for Haskell's Prelude, using the familiar symbols
-- in order to construct 'AST's and 'ABT's. This is only necessary
-- if we want to use Hakaru as an embedded language in Haskell, but
-- it also provides some examples of how to use the infrastructure.
--
-- TODO: is there a way to get rid of the need to specify @'[]@ everywhere in here? Some sort of distinction between the Var vs the Open parts of View?
----------------------------------------------------------------
module Language.Hakaru.Syntax.Prelude where

-- TODO: implement and use Prelude's fromInteger and fromRational, so we can use numeric literals!
import Prelude (Maybe(..), Bool(..), Int, Double, ($), flip, const, error)
import qualified Prelude
import           Data.Sequence        (Seq)
import qualified Data.Sequence        as Seq
import qualified Data.Text            as Text
import           Control.Category     (Category(..))
import           Data.Number.LogFloat (LogFloat)

import Language.Hakaru.Syntax.Nat
import Language.Hakaru.Syntax.DataKind
import Language.Hakaru.Syntax.Sing (Sing, SingI(sing))
import Language.Hakaru.Syntax.HClasses
import Language.Hakaru.Syntax.Coercion
import Language.Hakaru.Syntax.AST
import Language.Hakaru.Syntax.Datum
import Language.Hakaru.Syntax.ABT hiding (View(..))

----------------------------------------------------------------
----- Helper combinators for defining our EDSL
{-
Below we implement a lot of simple optimizations; however, these
optimizations only apply if the client uses the type class methods
to produce the AST. We should implement a stand-alone function which
performs these sorts of optimizations, as a program transformation.
-}
-- TODO: constant propogation

-- TODO: NBE to get rid of administrative redexes.
app :: (ABT AST abt) => abt '[] (a ':-> b) -> abt '[] a -> abt '[] b
app e1 e2 = syn (App_ :$ e1 :* e2 :* End)

app2 :: (ABT AST abt) => abt '[] (a ':-> b ':-> c) -> abt '[] a -> abt '[] b -> abt '[] c
app2 = (app .) . app

app3 :: (ABT AST abt) => abt '[] (a ':-> b ':-> c ':-> d) -> abt '[] a -> abt '[] b -> abt '[] c -> abt '[] d
app3 = (app2 .) . app

primOp0_ :: (ABT AST abt) => PrimOp '[] a -> abt '[] a
primOp0_ o = syn (PrimOp_ o :$ End)

primOp1_
    :: (ABT AST abt)
    => PrimOp '[ a ] b
    -> abt '[] a -> abt '[] b
primOp1_ o e1 = syn (PrimOp_ o :$ e1 :* End)

primOp2_
    :: (ABT AST abt)
    => PrimOp '[ a, b ] c
    -> abt '[] a -> abt '[] b -> abt '[] c
primOp2_ o e1 e2 = syn (PrimOp_ o :$ e1 :* e2 :* End)

primOp3_
    :: (ABT AST abt)
    => PrimOp '[ a, b, c ] d
    -> abt '[] a -> abt '[] b -> abt '[] c -> abt '[] d
primOp3_ o e1 e2 e3 = syn (PrimOp_ o :$ e1 :* e2 :* e3 :* End)

measure0_ :: (ABT AST abt) => MeasureOp '[] a -> abt '[] ('HMeasure a)
measure0_ o = syn (MeasureOp_ o :$ End)

measure1_
    :: (ABT AST abt)
    => MeasureOp '[ a ] b
    -> abt '[] a -> abt '[] ('HMeasure b)
measure1_ o e1 = syn (MeasureOp_ o :$ e1 :* End)

measure2_
    :: (ABT AST abt)
    => MeasureOp '[ a, b ] c
    -> abt '[] a -> abt '[] b -> abt '[] ('HMeasure c)
measure2_ o e1 e2 = syn (MeasureOp_ o :$ e1 :* e2 :* End)


-- N.B., we don't take advantage of commutativity, for more predictable
-- AST outputs. However, that means we can end up being slow...
--
-- N.B., we also don't try to eliminate the identity elements or
-- do cancellations because (a) it's undecidable in general, and
-- (b) that's prolly better handled as a post-processing simplification
-- step
--
-- TODO: generalize these two from [] to Foldable?

-- | Apply an n-ary operator to a list. This smart constructor will
-- flatten nested calls to the same operator. And if there is exactly
-- one element in the flattened sequence, then it will remove the
-- 'NaryOp_' node from the AST.
--
-- N.B., if the flattened sequence is empty, this smart constructor
-- will return an AST which applies the operator to the empty
-- sequence; which may or may not be unsafe. If the operator has
-- an identity element, then it's fine (operating on the empty
-- sequence evaluates to the identity element). However, if the
-- operator doesn't have an identity, then the generated code will
-- error whenever we attempt to run it.
unsafeNaryOp_ :: (ABT AST abt) => NaryOp a -> [abt '[] a] -> abt '[] a
unsafeNaryOp_ o = naryOp_withIdentity o (syn $ NaryOp_ o Seq.empty)


-- | A variant of 'unsafeNaryOp_' which will replace operating over
-- the empty sequence with a specified identity element. The produced
-- AST has the same semantics, we're just preemptively
-- evaluating\/simplifying the 'NaryOp_' node of the AST.
--
-- N.B., this function does not simplify away the identity element
-- if it exists in the flattened sequence! We should add that in
-- the future.
naryOp_withIdentity
    :: (ABT AST abt) => NaryOp a -> abt '[] a -> [abt '[] a] -> abt '[] a
naryOp_withIdentity o i = go Seq.empty
    where
    go es [] =
        case Seq.viewl es of
        Seq.EmptyL   -> i
        e Seq.:< es' ->
            case Seq.viewl es' of
            Seq.EmptyL -> e
            _          -> syn $ NaryOp_ o es
    go es (e:es') =
        case matchNaryOp o e of
        Nothing   -> go (es Seq.|> e)    es'
        Just es'' -> go (es Seq.>< es'') es'


-- TODO: is this actually worth breaking out, performance-wise? Or should we simply use:
-- > naryOp2_ o x y = unsafeNaryOp_ o [x,y]
naryOp2_ :: (ABT AST abt) => NaryOp a -> abt '[] a -> abt '[] a -> abt '[] a
naryOp2_ o x y =
    case (matchNaryOp o x, matchNaryOp o y) of
    (Just xs, Just ys) -> syn . NaryOp_ o $ xs Seq.>< ys
    (Just xs, Nothing) -> syn . NaryOp_ o $ xs Seq.|> y
    (Nothing, Just ys) -> syn . NaryOp_ o $ x  Seq.<| ys
    (Nothing, Nothing) -> syn . NaryOp_ o $ x  Seq.<| Seq.singleton y


matchNaryOp
    :: (ABT AST abt) => NaryOp a -> abt '[] a -> Maybe (Seq (abt '[] a))
matchNaryOp o e =
    caseVarSyn e
        (const Nothing)
        $ \t ->
            case t of
            NaryOp_ o' xs | o' Prelude.== o -> Just xs
            _ -> Nothing


----------------------------------------------------------------
----------------------------------------------------------------
----- Now for the actual EDSL

{-
infixr 9 `pair`

infixr 1 =<<
infixr 1 <=<, >=>
infixr 9 .
infixr 0 $
-}

infixl 1 >>=, >>
infixr 2 ||
infixr 3 &&
infix  4 ==, /=, <, <=, >, >=
infixl 4 <$>, <*>, <*, *> -- <$
infixl 6 +, -
infixl 7 *, /
infixr 8 ^, ^^, **
-- infixl9 is the default when things are unspecified
infixl 9 !, `app`, `thRootOf`

-- TODO: some infix notation reminiscent of \"::\"
ann_ :: (ABT AST abt) => Sing a -> abt '[] a -> abt '[] a
ann_ typ e = syn (Ann_ typ :$ e :* End)

-- TODO: cancellation; constant coercion
coerceTo_ :: (ABT AST abt) => Coercion a b -> abt '[] a -> abt '[] b
coerceTo_ c e =
    Prelude.maybe (syn $ CoerceTo_ c :$ e :* End) id
        $ caseVarSyn e
            (const Nothing)
            $ \t ->
                case t of
                CoerceTo_ c' :$ es' ->
                    case es' of
                    e' :* End ->
                        Just . syn $ CoerceTo_ (c . c') :$ e' :* End
                    _ -> error "coerceTo_: the impossible happened"
                _ -> Nothing

unsafeFrom_ :: (ABT AST abt) => Coercion a b -> abt '[] b -> abt '[] a
unsafeFrom_ c e =
    Prelude.maybe (syn $ UnsafeFrom_ c :$ e :* End) id
        $ caseVarSyn e
            (const Nothing)
            $ \t ->
                case t of
                UnsafeFrom_ c' :$ es' ->
                    case es' of
                    e' :* End ->
                        Just . syn $ UnsafeFrom_ (c' . c) :$ e' :* End
                    _ -> error "unsafeFrom_: the impossible happened"
                _ -> Nothing

value_ :: (ABT AST abt) => Value a  -> abt '[] a
value_ = syn . Value_
bool_  :: (ABT AST abt) => Bool     -> abt '[] HBool
bool_  = syn . Value_ . VDatum . (\b -> if b then dTrue else dFalse)
nat_   :: (ABT AST abt) => Nat      -> abt '[] 'HNat
nat_   = value_ . VNat
int_   :: (ABT AST abt) => Int      -> abt '[] 'HInt
int_   = value_ . VInt
prob_  :: (ABT AST abt) => LogFloat -> abt '[] 'HProb
prob_  = value_ . VProb
real_  :: (ABT AST abt) => Double   -> abt '[] 'HReal
real_  = value_ . VReal

-- Boolean operators
true, false :: (ABT AST abt) => abt '[] HBool
true  = bool_ True
false = bool_ False

-- TODO: simplifications: distribution, constant-propogation
-- TODO: do we really want to distribute /by default/? Clearly we'll want to do that in some optimization\/partial-evaluation pass, but do note that it makes terms larger in general...
not :: (ABT AST abt) => abt '[] HBool -> abt '[] HBool
not e =
    Prelude.maybe (primOp1_ Not e) id
        $ caseVarSyn e
            (const Nothing)
            $ \t ->
                case t of
                PrimOp_ Not :$ es' ->
                    case es' of
                    e' :* End -> Just e'
                    _         -> error "not: the impossible happened"
                NaryOp_ And xs ->
                    Just . syn . NaryOp_ Or  $ Prelude.fmap not xs
                NaryOp_ Or xs ->
                    Just . syn . NaryOp_ And $ Prelude.fmap not xs
                NaryOp_ Xor xs ->
                    Just . syn . NaryOp_ Iff $ Prelude.fmap not xs
                NaryOp_ Iff xs ->
                    Just . syn . NaryOp_ Xor $ Prelude.fmap not xs
                Value_ v ->
                    case v of
                    VDatum (Datum _ (Inl Done))       -> Just false
                    VDatum (Datum _ (Inr (Inl Done))) -> Just true
                    _ -> error "not: the impossible happened"
                _ -> Nothing

and, or :: (ABT AST abt) => [abt '[] HBool] -> abt '[] HBool
and = naryOp_withIdentity And true
or  = naryOp_withIdentity Or  false

(&&), (||),
    -- (</=>), (<==>), (==>), (<==), (\\), (//) -- TODO: better names?
    nand, nor
    :: (ABT AST abt) => abt '[] HBool -> abt '[] HBool -> abt '[] HBool
(&&) = naryOp2_ And
(||) = naryOp2_ Or
-- (</=>) = naryOp2_ Xor
-- (<==>) = naryOp2_ Iff
-- (==>)  = primOp2_ Impl
-- (<==)  = flip (==>)
-- (\\)   = primOp2_ Diff
-- (//)   = flip (\\)
nand   = primOp2_ Nand
nor    = primOp2_ Nor


-- HEq & HOrder operators
(==), (/=)
    :: (ABT AST abt, HEq_ a) => abt '[] a -> abt '[] a -> abt '[] HBool
(==) = primOp2_ $ Equal hEq
(/=) = (not .) . (==)

(<), (<=), (>), (>=)
    :: (ABT AST abt, HOrd_ a) => abt '[] a -> abt '[] a -> abt '[] HBool
(<)    = primOp2_ $ Less hOrd
x <= y = not (x > y) -- or: @(x < y) || (x == y)@
(>)    = flip (<)
(>=)   = flip (<=)

min, max :: (ABT AST abt, HOrd_ a) => abt '[] a -> abt '[] a -> abt '[] a
min = naryOp2_ $ Min hOrd
max = naryOp2_ $ Max hOrd

-- TODO: if @a@ is bounded, then we can make these safe...
minimum, maximum :: (ABT AST abt, HOrd_ a) => [abt '[] a] -> abt '[] a
minimum = unsafeNaryOp_ $ Min hOrd
maximum = unsafeNaryOp_ $ Max hOrd


-- HSemiring operators
(+), (*)
    :: (ABT AST abt, HSemiring_ a) => abt '[] a -> abt '[] a -> abt '[] a
(+) = naryOp2_ $ Sum  hSemiring
(*) = naryOp2_ $ Prod hSemiring

-- TODO: more legit implementations for these two
zero, one :: (ABT AST abt, HSemiring_ a) => abt '[] a
zero = syn $ NaryOp_ (Sum  hSemiring) Seq.empty
one  = syn $ NaryOp_ (Prod hSemiring) Seq.empty

sum, product :: (ABT AST abt, HSemiring_ a) => [abt '[] a] -> abt '[] a
sum     = naryOp_withIdentity (Sum  hSemiring) zero
product = naryOp_withIdentity (Prod hSemiring) one

{-
sum, product :: (ABT AST abt, HSemiring_ a) => [abt '[] a] -> abt '[] a
sum     = unsafeNaryOp_ $ Sum  hSemiring
product = unsafeNaryOp_ $ Prod hSemiring
-}


-- TODO: simplifications
(^) :: (ABT AST abt, HSemiring_ a)
    => abt '[] a -> abt '[] 'HNat -> abt '[] a
(^) = primOp2_ $ NatPow hSemiring

-- TODO: this is actually safe, how can we capture that?
-- TODO: is this type restruction actually helpful anywhere for us?
-- If so, we ought to make this function polymorphic so that we can
-- use it for non-HRing HSemirings too...
square :: (ABT AST abt, HRing_ a) => abt '[] a -> abt '[] (NonNegative a)
square e = unsafeFrom_ signed (e ^ nat_ 2)


-- HRing operators
(-) :: (ABT AST abt, HRing_ a) => abt '[] a -> abt '[] a -> abt '[] a
x - y = x + negate y


-- TODO: do we really want to distribute negation over addition /by
-- default/? Clearly we'll want to do that in some
-- optimization\/partial-evaluation pass, but do note that it makes
-- terms larger in general...
negate :: (ABT AST abt, HRing_ a) => abt '[] a -> abt '[] a
negate e =
    Prelude.maybe (primOp1_ (Negate hRing) e) id
        $ caseVarSyn e
            (const Nothing)
            $ \t ->
                case t of
                -- TODO: need we case analyze the @HSemiring@?
                NaryOp_ (Sum theSemi) xs ->
                    Just . syn . NaryOp_ (Sum theSemi) $ Prelude.fmap negate xs
                -- TODO: need we case analyze the @HRing@?
                PrimOp_ (Negate _theRing) :$ es' ->
                    case es' of
                    e' :* End -> Just e'
                    _         -> error "negate: the impossible happened"
                _ -> Nothing


-- TODO: test case: @negative . square@ simplifies away the intermediate coercions. (cf., normal')
-- BUG: this can lead to ambiguity when used with the polymorphic functions of RealProb.
-- | An occasionally helpful variant of 'negate'.
negative :: (ABT AST abt, HRing_ a) => abt '[] (NonNegative a) -> abt '[] a
negative = negate . coerceTo_ signed


abs :: (ABT AST abt, HRing_ a) => abt '[] a -> abt '[] a
abs = coerceTo_ signed . abs_

abs_ :: (ABT AST abt, HRing_ a) => abt '[] a -> abt '[] (NonNegative a)
abs_ e = 
    Prelude.maybe (primOp1_ (Abs hRing) e) id
        $ caseVarSyn e
            (const Nothing)
            $ \t ->
                case t of
                -- BUG: can't use the 'Signed' pattern synonym here, because that /requires/ the input to be (NonNegative a), instead of giving us the information that it is.
                -- TODO: need we case analyze the @HRing@?
                CoerceTo_ (CCons (Signed _theRing) CNil) :$ es' ->
                    case es' of
                    e' :* End -> Just e'
                    _         -> error "abs_: the impossible happened"
                _ -> Nothing


-- TODO: any obvious simplifications? idempotent?
signum :: (ABT AST abt, HRing_ a) => abt '[] a -> abt '[] a
signum = primOp1_ $ Signum hRing


-- HFractional operators
(/) :: (ABT AST abt, HFractional_ a) => abt '[] a -> abt '[] a -> abt '[] a
x / y = x * recip y


-- TODO: generalize this pattern so we don't have to repeat it...
--
-- TODO: do we really want to distribute reciprocal over multiplication
-- /by default/? Clearly we'll want to do that in some
-- optimization\/partial-evaluation pass, but do note that it makes
-- terms larger in general...
recip :: (ABT AST abt, HFractional_ a) => abt '[] a -> abt '[] a
recip e0 =
    Prelude.maybe (primOp1_ (Recip hFractional) e0) id
        $ caseVarSyn e0
            (const Nothing)
            $ \t0 ->
                case t0 of
                -- TODO: need we case analyze the @HSemiring@?
                NaryOp_ (Prod theSemi) xs ->
                    Just . syn . NaryOp_ (Prod theSemi) $ Prelude.fmap recip xs
                -- TODO: need we case analyze the @HFractional@?
                PrimOp_ (Recip _theFrac) :$ es' ->
                    case es' of
                    e :* End -> Just e
                    _ -> error "recip: the impossible happened"
                _ -> Nothing


-- TODO: simplifications
-- TODO: a variant of 'if_' which gives us the evidence that the argument is non-negative, so we don't need to coerce or use 'abs_'
(^^) :: (ABT AST abt, HFractional_ a)
    => abt '[] a -> abt '[] 'HInt -> abt '[] a
x ^^ y =
    if_ (y < int_ 0)
        (recip x ^ abs_ y)
        (x ^ abs_ y)


-- HRadical operators
-- N.B., HProb is the only HRadical type (for now...)
-- TODO: simplifications
thRootOf
    :: (ABT AST abt, HRadical_ a)
    => abt '[] 'HNat -> abt '[] a -> abt '[] a
n `thRootOf` x = primOp2_ (NatRoot hRadical) x n

sqrt :: (ABT AST abt, HRadical_ a) => abt '[] a -> abt '[] a
sqrt = (nat_ 2 `thRootOf`)

{-
-- TODO: simplifications
(^+) :: (ABT AST abt, HRadical_ a)
    => abt '[] a -> abt '[] 'HPositiveRational -> abt '[] a
x ^+ y = casePositiveRational y $ \n d -> d `thRootOf` (x ^ n)

(^*) :: (ABT AST abt, HRadical_ a)
    => abt '[] a -> abt '[] 'HRational -> abt '[] a
x ^* y = caseRational y $ \n d -> d `thRootOf` (x ^^ n)
-}

betaFunc
    :: (ABT AST abt) => abt '[] 'HProb -> abt '[] 'HProb -> abt '[] 'HProb
betaFunc = primOp2_ BetaFunc


integrate
    :: (ABT AST abt)
    => abt '[] 'HReal
    -> abt '[] 'HReal
    -> (abt '[] 'HReal -> abt '[] 'HProb)
    -> abt '[] 'HProb
integrate lo hi f =
    primOp3_ Integrate lo hi (lam f)

summate
    :: (ABT AST abt)
    => abt '[] 'HReal
    -> abt '[] 'HReal
    -> (abt '[] 'HInt -> abt '[] 'HProb)
    -> abt '[] 'HProb
summate lo hi f =
    primOp3_ Summate lo hi (lam f)


-- HACK: we define this class in order to gain more polymorphism;
-- but, will it cause type inferencing issues? Excepting 'log'
-- (which should be moved out of the class) these are all safe.
class RealProb (a :: Hakaru) where
    (**) :: (ABT AST abt) => abt '[] 'HProb -> abt '[] a -> abt '[] 'HProb
    exp  :: (ABT AST abt) => abt '[] a -> abt '[] 'HProb
    log  :: (ABT AST abt) => abt '[] 'HProb -> abt '[] a -- HACK
    erf  :: (ABT AST abt) => abt '[] a -> abt '[] a
    pi   :: (ABT AST abt) => abt '[] a
    infinity :: (ABT AST abt) => abt '[] a
    gammaFunc :: (ABT AST abt) => abt '[] a -> abt '[] 'HProb

instance RealProb 'HReal where
    (**)      = primOp2_ RealPow
    exp       = primOp1_ Exp
    log       = primOp1_ Log
    erf       = primOp1_ $ Erf hContinuous
    pi        = fromProb $ primOp0_ Pi
    infinity  = fromProb $ primOp0_ Infinity
    gammaFunc = primOp1_ GammaFunc

instance RealProb 'HProb where
    x ** y    = primOp2_ RealPow x $ fromProb y
    exp       = primOp1_ Exp . fromProb
    log       = unsafeProb . primOp1_ Log -- error for inputs in [0,1)
    erf       = primOp1_ $ Erf hContinuous
    pi        = primOp0_ Pi
    infinity  = primOp0_ Infinity
    gammaFunc = primOp1_ GammaFunc . fromProb

logBase
    :: (ABT AST abt, RealProb a, HFractional_ a)
    => abt '[] 'HProb
    -> abt '[] 'HProb
    -> abt '[] a
logBase b x = log x / log b -- undefined when b == 1

sin, cos, tan, asin, acos, atan, sinh, cosh, tanh, asinh, acosh, atanh
    :: (ABT AST abt) => abt '[] 'HReal -> abt '[] 'HReal
sin    = primOp1_ Sin
cos    = primOp1_ Cos
tan    = primOp1_ Tan
asin   = primOp1_ Asin
acos   = primOp1_ Acos
atan   = primOp1_ Atan
sinh   = primOp1_ Sinh
cosh   = primOp1_ Cosh
tanh   = primOp1_ Tanh
asinh  = primOp1_ Asinh
acosh  = primOp1_ Acosh
atanh  = primOp1_ Atanh


----------------------------------------------------------------
-- TODO: whenever all children are 'value_' then automagically use 'vdatum' rather than the raw syntax of 'datum_'
datum_
    :: (ABT AST abt)
    => Datum (abt '[]) (HData' t)
    -> abt '[] (HData' t)
datum_ = syn . Datum_

vdatum
    :: (ABT AST abt)
    => Datum Value (HData' t)
    -> abt '[] (HData' t)
vdatum = value_ . VDatum

unit   :: (ABT AST abt) => abt '[] HUnit
unit   = vdatum dUnit

pair   :: (ABT AST abt) => abt '[] a -> abt '[] b -> abt '[] (HPair a b)
pair   = (datum_ .) . dPair


-- BUG: N.B., this doesn't work when @a@ or @b@ are HData, because the SingI instance for Symbol isn't implemented! (But other than that, this seems to work...)
unpair
    :: forall abt a b c
    .  (ABT AST abt, SingI a, SingI b)
    => abt '[] (HPair a b)
    -> (abt '[] a -> abt '[] b -> abt '[] c)
    -> abt '[] c
unpair e f = error "TODO: unpair with the new 'Variable' type"
{-
    -- HACK: the current implementation of 'multibinder' requires this explicit type signature.
    -- BUG: why do we get a warning about the pattern being non-exhaustive?
    let f' :: List1 abt (a ': b ': '[]) -> abt c
        f' (Cons x (Cons y Nil)) = f x y
        f' _ = error "unpair: the impossible happened"
    in syn $ Case_ e
        [Branch (pPair PVar PVar)
            $ multibinder
                ( Cons (Hint Text.empty sing)
                . Cons (Hint Text.empty sing)
                $ Nil)
                f'
        ]
-}

fst :: (ABT AST abt, SingI a, SingI b)
    => abt '[] (HPair a b)
    -> abt '[] a
fst p = unpair p (\x _ -> x)

snd :: (ABT AST abt, SingI a, SingI b)
    => abt '[] (HPair a b)
    -> abt '[] b
snd p = unpair p (\_ y -> y)

left :: (ABT AST abt) => abt '[] a -> abt '[] (HEither a b)
left = datum_ . dLeft

right :: (ABT AST abt) => abt '[] b -> abt '[] (HEither a b)
right = datum_ . dRight

uneither
    :: (ABT AST abt, SingI a, SingI b)
    => abt '[] (HEither a b)
    -> (abt '[] a -> abt '[] c)
    -> (abt '[] b -> abt '[] c)
    -> abt '[] c
uneither e l r = 
    syn $ Case_ e
        [ Branch (pLeft  PVar) (binder Text.empty sing l)
        , Branch (pRight PVar) (binder Text.empty sing r)
        ]

if_ :: (ABT AST abt) => abt '[] HBool -> abt '[] a -> abt '[] a -> abt '[] a
if_ b t f =
    syn $ Case_ b
        [ Branch pTrue  t
        , Branch pFalse f
        ]

nil      :: (ABT AST abt) => abt '[] (HList a)
nil      = vdatum dNil

cons     :: (ABT AST abt) => abt '[] a -> abt '[] (HList a) -> abt '[] (HList a)
cons     = (datum_ .) . dCons

list     :: (ABT AST abt) => [abt '[] a] -> abt '[] (HList a)
list     = Prelude.foldr cons nil

nothing  :: (ABT AST abt) => abt '[] (HMaybe a)
nothing  = vdatum dNothing

just     :: (ABT AST abt) => abt '[] a -> abt '[] (HMaybe a)
just     = datum_ . dJust

maybe    :: (ABT AST abt) => Maybe (abt '[] a) -> abt '[] (HMaybe a)
maybe    = Prelude.maybe nothing just


unsafeProb :: (ABT AST abt) => abt '[] 'HReal -> abt '[] 'HProb
unsafeProb = unsafeFrom_ signed

fromProb   :: (ABT AST abt) => abt '[] 'HProb -> abt '[] 'HReal
fromProb   = coerceTo_ signed

nat2int    :: (ABT AST abt) => abt '[] 'HNat -> abt '[] 'HInt
nat2int    = coerceTo_ signed

fromInt    :: (ABT AST abt) => abt '[] 'HInt  -> abt '[] 'HReal
fromInt    = coerceTo_ continuous

nat2prob   :: (ABT AST abt) => abt '[] 'HNat  -> abt '[] 'HProb
nat2prob   = coerceTo_ continuous

negativeInfinity :: (ABT AST abt) => abt '[] 'HReal
negativeInfinity = primOp0_ NegativeInfinity

fix :: (ABT AST abt, SingI a) => (abt '[] a -> abt '[] a) -> abt '[] a
fix f = syn (Fix_ :$ binder Text.empty sing f :* End)

-- instance (ABT AST abt) => Lambda abt where
-- 'app' already defined

lam :: (ABT AST abt, SingI a)
    => (abt '[] a -> abt '[] b)
    -> abt '[] (a ':-> b)
lam = lamWithType sing

lamWithType
    :: (ABT AST abt)
    => Sing a
    -> (abt '[] a -> abt '[] b)
    -> abt '[] (a ':-> b)
lamWithType typ f = syn (Lam_ :$ binder Text.empty typ f :* End)

{-
-- some test cases to make sure we tied-the-knot successfully:
> let
    lam :: (ABT AST abt)
        => String
        -> Sing a
        -> (abt '[] a -> abt '[] b)
        -> abt '[] (a ':-> b)
    lam name typ f = syn (Lam_ :$ binder name typ f :* End)
> lam "x" SInt (\x -> x) :: TrivialABT AST ('HInt ':-> 'HInt)
> lam "x" SInt (\x -> lam "y" SInt $ \y -> x < y) :: TrivialABT AST ('HInt ':-> 'HInt ':-> 'HBool)
-}

let_
    :: (ABT AST abt, SingI a)
    => abt '[] a
    -> (abt '[] a -> abt '[] b)
    -> abt '[] b
let_ e f = syn (Let_ :$ e :* binder Text.empty sing f :* End)


----------------------------------------------------------------
array
    :: (ABT AST abt)
    => abt '[] 'HNat
    -> (abt '[] 'HNat -> abt '[] a)
    -> abt '[] ('HArray a)
array n =
    syn . Array_ n . binder Text.empty sing

empty :: (ABT AST abt) => abt '[] ('HArray a)
empty = syn Empty_

-- BUG: remove the 'SingI' requirement!
(!) :: (ABT AST abt, SingI a)
    => abt '[] ('HArray a) -> abt '[] 'HNat -> abt '[] a
(!) = primOp2_ $ Index sing

-- BUG: remove the 'SingI' requirement!
size :: (ABT AST abt, SingI a) => abt '[] ('HArray a) -> abt '[] 'HNat
size = primOp1_ $ Size sing

-- BUG: remove the 'SingI' requirement!
reduce
    :: (ABT AST abt, SingI a)
    => (abt '[] a -> abt '[] a -> abt '[] a)
    -> abt '[] a
    -> abt '[] ('HArray a)
    -> abt '[] a
reduce f = primOp3_ (Reduce sing) (lam $ \x -> lam $ \y -> f x y)

-- TODO: better names for all these. The \"V\" suffix doesn't make sense anymore since we're calling these arrays, not vectors...
-- TODO: bust these all out into their own place, since the API for arrays is gonna be huge

-- BUG: remove the 'SingI' requirement!
sumV :: (ABT AST abt, HSemiring_ a, SingI a)
    => abt '[] ('HArray a) -> abt '[] a
sumV = reduce (+) zero -- equivalent to summateV if @a ~ 'HProb@

summateV :: (ABT AST abt) => abt '[] ('HArray 'HProb) -> abt '[] 'HProb
summateV x =
    summate (real_ 0) (fromInt $ nat2int (size x) - int_ 1)
        (\i -> x ! unsafeFrom_ signed i)

-- TODO: a variant of 'if_' for giving us evidence that the subtraction is sound.

unsafeMinusNat
    :: (ABT AST abt) => abt '[] 'HNat -> abt '[] 'HNat -> abt '[] 'HNat
unsafeMinusNat x y = unsafeFrom_ signed (nat2int x - nat2int y)

unsafeMinusProb
    :: (ABT AST abt) => abt '[] 'HProb -> abt '[] 'HProb -> abt '[] 'HProb
unsafeMinusProb x y = unsafeProb (fromProb x - fromProb y)

{-
-- BUG: the general version won't typecheck because we run into ambiguity issues due to NonNegative not being injective... Basically, we need to concretize the choice of @a@ given @NonNegative a@
unsafeMinus
    :: (ABT AST abt, HRing_ a)
    => abt '[] (NonNegative a)
    -> abt '[] (NonNegative a)
    -> abt '[] (NonNegative a)
unsafeMinus x y =
    unsafeFrom_ signed (coerceTo_ signed x - coerceTo_ signed y)
-}

-- BUG: remove the 'SingI' requirement!
appendV
    :: (ABT AST abt, SingI a)
    => abt '[] ('HArray a) -> abt '[] ('HArray a) -> abt '[] ('HArray a)
appendV v1 v2 =
    array (size v1 + size v2) $ \i ->
        if_ (i < size v1)
            (v1 ! i)
            (v2 ! (i `unsafeMinusNat` size v1))

-- BUG: remove the 'SingI' requirement!
mapWithIndex
    :: (ABT AST abt, SingI a)
    => (abt '[] 'HNat -> abt '[] a -> abt '[] b)
    -> abt '[] ('HArray a)
    -> abt '[] ('HArray b)
mapWithIndex f v = array (size v) $ \i -> f i (v ! i)

-- BUG: remove the 'SingI' requirement!
mapV
    :: (ABT AST abt, SingI a)
    => (abt '[] a -> abt '[] b)
    -> abt '[] ('HArray a)
    -> abt '[] ('HArray b)
mapV f v = array (size v) $ \i -> f (v ! i)

normalizeV
    :: (ABT AST abt) => abt '[] ('HArray 'HProb) -> abt '[] ('HArray 'HProb)
normalizeV x = mapV (/ summateV x) x -- TODO: why summateV instead of sumV?

constV :: (ABT AST abt) => abt '[] 'HNat -> abt '[] b -> abt '[] ('HArray b)
constV n c = array n (const c)

-- TODO: zipWithV

----------------------------------------------------------------
-- BUG: remove the 'SingI' requirement!
(>>=)
    :: (ABT AST abt, SingI a)
    => abt '[] ('HMeasure a)
    -> (abt '[] a -> abt '[] ('HMeasure b))
    -> abt '[] ('HMeasure b)
m >>= f =
    case
        caseVarSyn m (const Nothing) $ \t ->
            case t of
            Dirac :$ e1 :* End -> Just e1
            _                  -> Nothing
    of
    Nothing -> syn (MBind :$ m :* binder Text.empty sing f :* End)
    Just e1 -> let_ e1 f


dirac :: (ABT AST abt) => abt '[] a -> abt '[] ('HMeasure a)
dirac e1 = syn (Dirac :$ e1 :* End)


-- TODO: can we use let-binding instead of (>>=)-binding (i.e., for when the dirac is immediately (>>=)-bound again...)?
-- BUG: remove the 'SingI' requirement!
(<$>), liftM
    :: (ABT AST abt, SingI a)
    => (abt '[] a -> abt '[] b)
    -> abt '[] ('HMeasure a)
    -> abt '[] ('HMeasure b)
f <$> m = m >>= dirac . f
liftM = (<$>)

-- BUG: remove the 'SingI' requirement!
-- | N.B, this function may introduce administrative redexes.
-- Moreover, it's not clear that we should even allow the type
-- @'HMeasure (a ':-> b)@!
(<*>)
    :: (ABT AST abt, SingI a, SingI b)
    => abt '[] ('HMeasure (a ':-> b))
    -> abt '[] ('HMeasure a)
    -> abt '[] ('HMeasure b)
mf <*> mx = mf >>= \f -> app f <$> mx

-- TODO: ensure that @dirac a *> n@ simplifies to just @n@, regardless of @a@ but especially when @a = unit@.
-- BUG: remove the 'SingI' requirement!
(*>), (>>)
    :: (ABT AST abt, SingI a)
    => abt '[] ('HMeasure a)
    -> abt '[] ('HMeasure b)
    -> abt '[] ('HMeasure b)
m *> n = m >>= \_ -> n
(>>) = (*>)

-- TODO: ensure that @m <* dirac a@ simplifies to just @m@, regardless of @a@ but especially when @a = unit@.
-- BUG: remove the 'SingI' requirements! especially on @b@!
(<*)
    :: (ABT AST abt, SingI a, SingI b)
    => abt '[] ('HMeasure a)
    -> abt '[] ('HMeasure b)
    -> abt '[] ('HMeasure a)
m <* n = m >>= \a -> n *> dirac a

-- BUG: remove the 'SingI' requirement!
bindx
    :: (ABT AST abt, SingI a, SingI b)
    => abt '[] ('HMeasure a)
    -> (abt '[] a -> abt '[] ('HMeasure b))
    -> abt '[] ('HMeasure (HPair a b))
m `bindx` f = m >>= \a -> pair a <$> f a

-- BUG: remove the 'SingI' requirement!
liftM2
    :: (ABT AST abt, SingI a, SingI b, SingI c)
    => (abt '[] a -> abt '[] b -> abt '[] c)
    -> abt '[] ('HMeasure a)
    -> abt '[] ('HMeasure b)
    -> abt '[] ('HMeasure c)
liftM2 f m n = m >>= \x -> f x <$> n
    -- or @(lam . f) <$> m <*> n@ but that would introduce administrative redexes


lebesgue :: (ABT AST abt) => abt '[] ('HMeasure 'HReal)
lebesgue = measure0_ Lebesgue

counting :: (ABT AST abt) => abt '[] ('HMeasure 'HInt)
counting = measure0_ Counting

-- TODO: make this smarter by collapsing nested @Superpose_@ similar to how we collapse nested NaryOps. Though beware, that could cause duplication of the computation for the probabilities\/weights; thus may want to only do it when the weights are constant values, or \"simplify\" things by generating let-bindings in order to share work.
superpose
    :: (ABT AST abt)
    => [(abt '[] 'HProb, abt '[] ('HMeasure a))]
    -> abt '[] ('HMeasure a)
superpose = syn . Superpose_

-- | The empty measure. Is called @fail@ in the Core Hakaru paper.
reject :: (ABT AST abt) => abt '[] ('HMeasure a)
reject = superpose []

-- TODO: define @mplus@ to better mimic Core Hakaru

-- TODO: we should ensure that @pose p m >> n@ simplifies to @pose p (m >> n)@; also ensure that @m >> pose p n@ simplifies to @pose p (m >> n)@; also that @pose 1 m@ simplifies to @m@ and @pose p (pose q m)@ simplifies to @pose (p*q) m@.
-- | Pose a given measure with some given weight. This generates
-- the singleton \"positions\" of 'superpose'.
--
-- /N.B.,/ the name for this function is terribly inconsistent
-- across the literature, even just the Hakaru literature, let alone
-- the Hakaru code base. It is variously called \"factor\" or
-- \"weight\"; though \"factor\" is also used to mean the function
-- 'factor' or the function 'observe', and \"weight\" is also used
-- to mean the 'weight' function.
--
-- (was formerly called @weight@ in this branch, as per the old Syntax.hs)
-- TODO: would @withWeight@ be a better name than @pose@?
-- TODO: ideally we'll be able to get rid of this function entirely, relying on 'weight' instead. Doing this effectively requires having certain optimizations for our ASTs.
pose
    :: (ABT AST abt)
    => abt '[] 'HProb
    -> abt '[] ('HMeasure w)
    -> abt '[] ('HMeasure w)
pose p m = superpose [(p, m)]

-- TODO: we should ensure that @m >> weight p@ simplifies to @pose p m@.
-- | Adjust the weight of the current measure.
--
-- /N.B.,/ the name for this function is terribly inconsistent
-- across the literature, even just the Hakaru literature, let alone
-- the Hakaru code base. It is often called \"factor\", though that
-- name is variously used to mean the 'pose' function or the 'observe'
-- function instead.
--
-- (was formerly called @factor@ in this branch, as per the old Syntax.hs)
weight
    :: (ABT AST abt)
    => abt '[] 'HProb
    -> abt '[] ('HMeasure HUnit)
weight p = pose p (dirac unit)

-- BUG: remove the 'SingI' requirement!
weightedDirac
    :: (ABT AST abt, SingI a)
    => abt '[] a
    -> abt '[] 'HProb
    -> abt '[] ('HMeasure a)
weightedDirac e p = pose p (dirac e)
    -- == weight p *> dirac e
    -- == dirac e <* weight p

-- TODO: this taking of two arguments is as per the Core Hakaru specification; but for the EDSL, can we rephrase this as just taking the first argument, using @dirac unit@ for the else-branch, and then, making @(>>)@ work in the right way to plug the continuation measure in place of the @dirac unit@.
-- TODO: would it help inference\/simplification at all to move this into the AST as a primitive? I mean, it is a primitive of Core Hakaru afterall... Also, that would help clarify whether the (first)argument should actually be an @HBool@ or whether it should be some sort of proposition.
-- | Assert that a condition is true.
--
-- TODO: rephrase to have the type @abt '[] HBool -> abt '[] ('HMeasure HUnit)@. Doing this effectively requires having certain optimizations for our ASTs.
--
-- /N.B.,/ the name for this function is terribly inconsistent
-- across the literature, even just the Hakaru literature, let alone
-- the Hakaru code base. It is variously called \"factor\" or
-- \"observe\"; though \"factor\" is also used to mean the function
-- 'pose', and \"observe\" is also used to mean the backwards part
-- of Lazy.hs.
--
-- (was formerly called @factor_@ in this branch; wasn't abstracted out in the old Syntax.hs)
observe
    :: (ABT AST abt)
    => abt '[] HBool
    -> abt '[] ('HMeasure a)
    -> abt '[] ('HMeasure a)
observe b m = if_ b m reject


categorical, categorical'
    :: (ABT AST abt)
    => abt '[] ('HArray 'HProb)
    -> abt '[] ('HMeasure 'HNat)
categorical = measure1_ Categorical

-- TODO: a variant of 'if_' which gives us the evidence that the argument is non-negative, so we don't need to coerce or use 'abs_'
categorical' v =
    counting >>= \i ->
    observe (int_ 0 <= i && i < nat2int (size v)) $
    let_ (abs_ i) $ \j ->
    weightedDirac j (v!j / sumV v)


-- TODO: make Uniform polymorphic, so that if the two inputs are
-- HProb then we know the measure must be over HProb too
uniform, uniform'
    :: (ABT AST abt)
    => abt '[] 'HReal
    -> abt '[] 'HReal
    -> abt '[] ('HMeasure 'HReal)
uniform = measure2_ Uniform

uniform' lo hi = 
    lebesgue >>= \x ->
    observe (lo < x && x < hi)
        -- TODO: how can we capture that this 'unsafeProb' is safe? (and that this 'recip' isn't Infinity, for that matter)
        $ weightedDirac x (recip . unsafeProb $ hi - lo)


normal, normal'
    :: (ABT AST abt)
    => abt '[] 'HReal
    -> abt '[] 'HProb
    -> abt '[] ('HMeasure 'HReal)
normal = measure2_ Normal

normal' mu sd  = 
    lebesgue >>= \x ->
    weightedDirac x
        -- alas, we loose syntactic negation...
        $ exp (negate ((x - mu) ^ nat_ 2)  -- TODO: use negative\/square instead of negate\/(^2)
            / fromProb (prob_ 2 * sd ^ nat_ 2)) -- TODO: use square?
            / sd / sqrt (prob_ 2 * pi)


poisson, poisson'
    :: (ABT AST abt) => abt '[] 'HProb -> abt '[] ('HMeasure 'HNat)
poisson = measure1_ Poisson

poisson' l = 
    counting >>= \x ->
    -- TODO: use 'SafeFrom_' instead of @if_ (x >= int_ 0)@ so we can prove that @unsafeFrom_ signed x@ is actually always safe.
    observe (int_ 0 <= x && prob_ 0 < l) -- N.B., @0 < l@ means simply that @l /= 0@; why phrase it the other way?
        $ weightedDirac (unsafeFrom_ signed x)
            $ l ^^ x
                / gammaFunc (fromInt (x + int_ 1)) -- TODO: use factorial instead of gammaFunc...
                / exp l


gamma, gamma'
    :: (ABT AST abt)
    => abt '[] 'HProb
    -> abt '[] 'HProb
    -> abt '[] ('HMeasure 'HProb)
gamma = measure2_ Gamma

gamma' shape scale =
    lebesgue >>= \x ->
    -- TODO: use 'SafeFrom_' instead of @if_ (real_ 0 < x)@ so we can prove that @unsafeProb x@ is actually always safe. Of course, then we'll need to mess around with checking (/=0) which'll get ugly... Use another SafeFrom_ with an associated NonZero type?
    observe (real_ 0 < x) $
    let_ (unsafeProb x) $ \ x_ ->
    weightedDirac x_
        $ x_ ** (fromProb shape - real_ 1)
            * exp (negate . fromProb $ x_ / scale)
            / (scale ** shape * gammaFunc shape)


beta, beta'
    :: (ABT AST abt)
    => abt '[] 'HProb
    -> abt '[] 'HProb
    -> abt '[] ('HMeasure 'HProb)
beta = measure2_ Beta

beta' a b =
    -- TODO: make Uniform polymorphic, so that if the two inputs are HProb then we know the measure must be over HProb too, and hence @unsafeProb x@ must always be safe. Alas, capturing the safety of @unsafeProb (1-x)@ would take a lot more work...
    unsafeProb <$> uniform (real_ 0) (real_ 1) >>= \x ->
    weightedDirac x
        $ x ** (fromProb a - real_ 1)
            * unsafeProb (real_ 1 - fromProb x) ** (fromProb b - real_ 1)
            / betaFunc a b


-- BUG: remove the 'SingI' requirement!
dp  :: (ABT AST abt, SingI a)
    => abt '[] 'HProb
    -> abt '[] ('HMeasure a)
    -> abt '[] ('HMeasure ('HMeasure a))
dp = measure2_ $ DirichletProcess sing


-- BUG: remove the 'SingI' requirement!
plate, plate'
    :: (ABT AST abt, SingI a)
    => abt '[] ('HArray ('HMeasure          a))
    -> abt '[] (         'HMeasure ('HArray a))
plate = measure1_ $ Plate sing

plate' v = reduce r z (mapV m v)
    where
    r   = liftM2 appendV
    z   = dirac empty
    m a = (array (nat_ 1) . const) <$> a


-- BUG: remove the 'SingI' requirement!
chain, chain'
    :: (ABT AST abt, SingI s, SingI a)
    => abt '[] ('HArray (s ':-> 'HMeasure (HPair a s)))
    -> abt '[] s
    -> abt '[] ('HMeasure (HPair ('HArray a) s))
chain = measure2_ $ Chain sing sing

chain' v s0 = reduce r z (mapV m v) `app` s0
    where
    r x y = lam $ \s ->
            app x s >>= \v1s1 ->
            v1s1 `unpair` \v1 s1 ->
            app y s1 >>= \v2s2 ->
            v2s2 `unpair` \v2 s2 ->
            dirac $ pair (appendV v1 v2) s2
    z     = lam $ \s -> dirac (pair empty s)
    m a   = lam $ \s -> (`unpair` pair . array (nat_ 1) . const) <$> app a s


invgamma
    :: (ABT AST abt)
    => abt '[] 'HProb
    -> abt '[] 'HProb
    -> abt '[] ('HMeasure 'HProb)
invgamma k t = recip <$> gamma k (recip t)

exponential :: (ABT AST abt) => abt '[] 'HProb -> abt '[] ('HMeasure 'HProb)
exponential = gamma (prob_ 1)

chi2 :: (ABT AST abt) => abt '[] 'HProb -> abt '[] ('HMeasure 'HProb)
chi2 v = gamma (v / prob_ 2) (prob_ 2)

cauchy
    :: (ABT AST abt)
    => abt '[] 'HReal
    -> abt '[] 'HProb
    -> abt '[] ('HMeasure 'HReal)
cauchy loc scale =
    normal (real_ 0) (prob_ 1) >>= \x ->
    normal (real_ 0) (prob_ 1) >>= \y ->
    dirac $ loc + fromProb scale * x / y

laplace
    :: (ABT AST abt)
    => abt '[] 'HReal
    -> abt '[] 'HProb
    -> abt '[] ('HMeasure 'HReal)
laplace loc scale =
    exponential (prob_ 1) >>= \v ->
    normal (real_ 0) (prob_ 1) >>= \z ->
    dirac $ loc + z * fromProb (scale * sqrt (prob_ 2 * v))

student
    :: (ABT AST abt)
    => abt '[] 'HReal
    -> abt '[] 'HProb
    -> abt '[] ('HMeasure 'HReal)
student loc v =
    normal loc (prob_ 1) >>= \z ->
    chi2 v >>= \df ->
    dirac $ z * fromProb (sqrt (v / df))

weibull
    :: (ABT AST abt)
    => abt '[] 'HProb
    -> abt '[] 'HProb
    -> abt '[] ('HMeasure 'HProb)
weibull b k =
    exponential (prob_ 1) >>= \x ->
    dirac $ b * x ** recip k

-- BUG: would it be better to 'observe' that @p <= 1@ before doing the superpose? At least that way things would be /defined/ for all inputs...
bern :: (ABT AST abt) => abt '[] 'HProb -> abt '[] ('HMeasure HBool)
bern p = superpose
    [ (p, dirac true)
    , (prob_ 1 `unsafeMinusProb` p, dirac false)
    ]

mix :: (ABT AST abt)
    => abt '[] ('HArray 'HProb) -> abt '[] ('HMeasure 'HNat)
mix v = pose (sumV v) (categorical v)

binomial
    :: (ABT AST abt)
    => abt '[] 'HNat
    -> abt '[] 'HProb
    -> abt '[] ('HMeasure 'HInt)
binomial n p =
    sumV <$> plate (constV n ((\b -> if_ b (int_ 1) (int_ 0)) <$> bern p))

-- BUG: would it be better to 'observe' that @p >= 1@ before doing everything? At least that way things would be /defined/ for all inputs...
negativeBinomial
    :: (ABT AST abt)
    => abt '[] 'HNat
    -> abt '[] 'HProb -- N.B., must actually be >= 1
    -> abt '[] ('HMeasure 'HNat)
negativeBinomial r p =
    gamma (nat2prob r) (recip p `unsafeMinusProb` prob_ 1) >>= poisson

geometric :: (ABT AST abt) => abt '[] 'HProb -> abt '[] ('HMeasure 'HNat)
geometric = negativeBinomial (nat_ 1)

{-
multinomial
    :: (ABT AST abt)
    => abt '[] 'HNat
    -> abt '[] ('HArray 'HProb)
    -> abt '[] ('HMeasure ('HArray 'HProb))
multinomial n v =
    reduce (liftM2 (zipWithV (+)))
        (dirac (constV (size v) 0))
        (constV n (unitV (size v) <$> categorical v))
-}

dirichlet
    :: (ABT AST abt)
    => abt '[] ('HArray 'HProb)
    -> abt '[] ('HMeasure ('HArray 'HProb))
dirichlet a = normalizeV <$> plate (mapV (`gamma` prob_ 1) a)

----------------------------------------------------------------
----------------------------------------------------------- fin.

{-# LANGUAGE OverloadedStrings, DataKinds, GADTs #-}

module Tests.Hakaru where

import qualified Language.Hakaru.Parser.AST as U
import Language.Hakaru.Parser.Parser
import Language.Hakaru.Parser.SymbolResolve


import qualified Language.Hakaru.Syntax.AST as T
import Language.Hakaru.Syntax.IClasses
import Language.Hakaru.Syntax.HClasses
import Language.Hakaru.Syntax.Nat
import Language.Hakaru.Syntax.ABT
import Language.Hakaru.Syntax.Sing
import Language.Hakaru.Syntax.DataKind

import Language.Hakaru.Syntax.TypeCheck
import Language.Hakaru.PrettyPrint
import Language.Hakaru.Sample hiding (SData, SKonst, SEt, SDone, SPlus, SVoid)
import Language.Hakaru.Expect
import Language.Hakaru.Syntax.Prelude (prob_, fromProb)

import Prelude hiding (unlines)
import Data.Text
import Text.PrettyPrint
import qualified System.Random.MWC as MWC

five, normal01, normalb, uniform01 :: Text

five = "2 + 3"
uniform01 = "uniform(-0.0,1.0)"
normal01  = "normal(-0.0,1.0)"

normalb   = unlines [ "x <~ normal(-2.0,1.0)"
                    , "y <~ normal(x, 1.0)"
                    , "return y"
                    ]

pToa :: U.AST' Text -> U.AST a
pToa = makeAST . normAST . (symbolResolution primTable)

inferType' :: U.AST a -> TypeCheckMonad (TypedAST (TrivialABT T.AST))
inferType' = inferType

testTC :: U.AST a -> String
testTC a = case runTCM (inferType' a) of
             Left err -> err
             Right (TypedAST typ ast) -> show (typ, pretty ast)

illustrate :: Sing a -> MWC.GenIO -> Sample IO a -> IO String
illustrate SNat  g x = return (show x)
illustrate SInt  g x = return (show x)
illustrate SProb g x = return (show x)
illustrate SReal g x = return (show x)
illustrate {- sPair s t -}
    (SData _ ((SKonst s `SEt` SKonst t `SEt` SDone) `SPlus` SVoid))
    g (x,y) = do
  str1 <- illustrate s g x
  str2 <- illustrate t g y
  return ("(" ++ str1 ++ "," ++ str2 ++ ")")
illustrate (SMeasure s) g m = do
  Just (samp,_) <- m 1 g
  illustrate s g samp
illustrate s _ _ = return ("<" ++ show s ++ ">")

testHakaru :: Text -> MWC.GenIO -> IO String
testHakaru a g = case parseHakaru a of
                 Left err -> return (show err)
                 Right past ->
                     let m = inferType' (pToa past) in
                     case runTCM m of
                       Left err -> return err
                       Right (TypedAST typ ast) -> do
                           putStrLn ("Type: " ++ show typ ++ "\n")
                           putStrLn ("AST: " ++ (show $ pretty ast) ++ "\n")
                           case typ of
                             SMeasure _ ->
                               putStrLn ("Expectation wrt 1 as ast: " ++
                                         (show $ pretty $
                                               expect ast (\x -> (prob_ 1))) ++ "\n")
                             _ -> return ()
                           illustrate typ g (unS (runSample' ast))
  where runSample' :: TrivialABT T.AST '[] a -> S IO a
        runSample' = runSample

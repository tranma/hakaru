{-# LANGUAGE TypeSynonymInstances
           , FlexibleInstances
           , DeriveDataTypeable
           , CPP
           , OverloadedStrings
           , ScopedTypeVariables
           #-}

{-# OPTIONS_GHC -Wall -fwarn-tabs #-}
----------------------------------------------------------------
--                                                    2015.10.18
-- |
-- Module      :  Language.Hakaru.Simplify
-- Copyright   :  Copyright (c) 2015 the Hakaru team
-- License     :  BSD3
-- Maintainer  :  wren@community.haskell.org
-- Stability   :  experimental
-- Portability :  GHC-only
--
-- Take strings from Maple and interpret them in Haskell (Hakaru)
----------------------------------------------------------------
module Language.Hakaru.Simplify
    ( closeLoop
    , simplify
    , toMaple
    , openLoop
    , main
    , Simplifiable(mapleType)
    , MapleException(MapleException)
    , InterpreterException(InterpreterException)
    ) where

import Control.Exception
import Language.Hakaru.Simplifiable (Simplifiable(mapleType))
import Language.Hakaru.Maple (Maple, runMaple)
import Language.Hakaru.Any (Any(Any), AnySimplifiable(AnySimplifiable))
import Language.Hakaru.PrettyPrint (pretty)
import System.IO (stderr, hPrint, hPutStrLn)
import Data.Typeable (Typeable, typeOf)
import Data.List (tails, stripPrefix)
import Data.Text (replace, pack, unpack)
import Data.Char (isSpace)
import System.MapleSSH (maple)
import Language.Haskell.Interpreter.Unsafe (unsafeRunInterpreterWithArgs)
import Language.Haskell.Interpreter (
#ifdef PATCHED_HINT
    unsafeInterpret,
#else
    interpret,
#endif
    InterpreterError(WontCompile), GhcError(GhcError),
    MonadInterpreter, set, get, OptionVal((:=)),
    searchPath, languageExtensions, Extension(UnknownExtension),
    loadModules, setImports)

import Language.Hakaru.Util.Lex (readMapleString)
import Language.Hakaru.Paths
----------------------------------------------------------------

data MapleException       = MapleException String String
    deriving Typeable
data InterpreterException = InterpreterException InterpreterError String
    deriving Typeable

-- Maple prints errors with "cursors" (^) which point to the specific position
-- of the error on the line above. The derived show instance doesn't preserve
-- positioning of the cursor.
instance Show MapleException where
    show (MapleException toMaple_ fromMaple) =
        "MapleException:\n" ++ fromMaple ++
        "\nafter sending to Maple:\n" ++ toMaple_

instance Show InterpreterException where
    show (InterpreterException (WontCompile es) cause) =
        "InterpreterException:\n" ++ unlines [ msg | GhcError msg <- es ] ++
        "\nwhile interpreting:\n" ++ cause
    show (InterpreterException err cause) =
        "InterpreterException:\n" ++ show err ++
        "\nwhile interpreting:\n" ++ cause

instance Exception MapleException

instance Exception InterpreterException

ourGHCOptions, ourSearchPath :: [String]
ourGHCOptions =
    case sandboxPackageDB of
    Nothing -> []
    Just xs -> "-no-user-package-db" : map ("-package-db " ++) xs

ourSearchPath = [ hakaruRoot ]

ourContext :: MonadInterpreter m => m ()
ourContext = do
    let modules = [ "Tests.Imports", "Tests.EmbedDatatypes" ]
    
    set [ searchPath := ourSearchPath ]
    
    loadModules modules
    
    -- "Tag" requires DataKinds to use type list syntax
    exts <- get languageExtensions
    set [ languageExtensions := (UnknownExtension "DataKinds" : exts) ]
    
    setImports modules


-- Type checking is fragile for this function. It compiles fine
-- from the commandline, but using `cabal repl` causes it to break
-- due to OverloadedStrings and (supposed) ambiguity about @a@ in
-- the Typeable constraint. I've patched those two issues up by
-- giving an explicit type signature to @s'@, and using ScopedTypeVariables
-- to form the argument to 'typeOf' (rather than using 'asTypeOf'-style
-- tricks). Then again, 'simplify' doesn't work inside `cabal repl`
-- anyways, due to some dependency packages being hidden for some
-- odd reason...
closeLoop :: forall a. (Typeable a) => String -> IO a
closeLoop s = do
    result <- unsafeRunInterpreterWithArgs ourGHCOptions $ do
        ourContext
#ifdef PATCHED_HINT
        unsafeInterpret s' typeStr
#else
        interpret s' undefined
#endif
    case result of
        Left err -> throw (InterpreterException err s')
        Right a -> return a
    where
    s' :: String
    s' = s ++ " :: " ++ typeStr

    typeStr = unpack
        $ replace ":" "Cons"
        $ replace "[]" "Nil"
        $ pack (show (typeOf (undefined :: a)))

mkTypeString :: (Simplifiable a) => String -> proxy a -> String
mkTypeString s t = "Typed(" ++ s ++ ", " ++ mapleType t ++ ")"

simplify :: (Simplifiable a) => Maple a -> IO (Any a)
simplify e = do
    hakaru <- simplify' e
    closeLoop ("Any (" ++ hakaru ++ ")")

simplify' :: (Simplifiable a) => Maple a -> IO String
simplify' e = do
    let slo = toMaple e
    hopeString <- maple ("timelimit(15,Haskell(SLO:-AST(SLO(" ++ slo ++ "))));")
    case readMapleString hopeString of
        Just hakaru -> return hakaru
        Nothing     -> throw (MapleException slo hopeString)

toMaple :: (Simplifiable a) => Maple a -> String
toMaple e = mkTypeString (runMaple e 0) e

main :: IO ()
main = action `catch` handler1 `catch` handler0 where
    action :: IO ()
    action = do
        s <- readFile "/tmp/t" -- getContents
        let (before, middle, after) = trim s
        middle' <- simplifyAny middle
        putStr (before ++ middle' ++ after)

    handler1 ::  InterpreterError -> IO ()
    handler1 (WontCompile es) =
        sequence_ [ hPutStrLn stderr msg | GhcError msg <- es ]
    handler1 exception = throw exception

    handler0 :: SomeException -> IO ()
    handler0 = hPrint stderr

trim :: String -> (String, String, String)
trim s =
    let (before, s') = span isSpace s
        (after', middle') = span isSpace (reverse s')
    in (before, reverse middle', reverse after')

simplifyAny :: String -> IO String
simplifyAny s = do
    (names, AnySimplifiable e) <- openLoop [] s
    Any e' <- simplify e
    return (show (pretty e')) -- BUG: the old version used @runPrettyPrintNamesPrec e' names 0@, but the new prettyprinter doesn't have provisions for name supplies since it doesn't need them; thus there are almost certainly hygiene issues here.

openLoop :: [String] -> String -> IO ([String], AnySimplifiable)
openLoop names s =
    fmap ((,) names) (closeLoop ("AnySimplifiable (" ++ s ++ ")")) `catch` h
  where
    h :: InterpreterException -> IO ([String], AnySimplifiable)
    h (InterpreterException (WontCompile es) _)
      | not (null unbound) && not (any (`elem` names) unbound)
      = openLoop (unbound ++ names) (unlines header ++ s)
      where unbound = [ init msg''
                      | GhcError msg <- es
                      , msg' <- tails msg
                      , Just msg'' <- [stripPrefix ": Not in scope: `" msg']
                      , last msg'' == '\'' ]
            header = [ "lam $ \\" ++ name ++ " ->" | name <- unbound ]
    h (InterpreterException exception _) = throw exception

----------------------------------------------------------------
----------------------------------------------------------- fin.
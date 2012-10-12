
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE OverlappingInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE UndecidableInstances #-}

module Formal.Optimize where
import System.IO.Unsafe

import Language.Javascript.JMacro

import Data.List (nub, (\\), intersect, union, partition)

import qualified Data.Map as M
import qualified Data.List as L
import qualified Data.Set as S

import Control.Monad
import Control.Applicative
import Data.Monoid
import Data.Char

import Text.ParserCombinators.Parsec

import Formal.Types.Literal
import Formal.Types.Pattern
import Formal.Types.Symbol
import Formal.Types.Expression
import Formal.Types.Definition
import Formal.Types.Axiom
import Formal.Types.Statement hiding (find, namespace, modules, Test)
import Formal.Types.Namespace hiding (Module)

import Formal.Types.TypeDefinition
import Formal.Types.Type

import Formal.TypeCheck hiding (get_namespace)

import Formal.Parser.Utils
import Formal.Parser

import qualified Formal.Javascript.Utils as J

type Inlines = [((Namespace, Symbol), (Match (Expression Definition), Expression Definition))]
type Inline  = [(Symbol, (Match (Expression Definition), Expression Definition))]

data OptimizeState = OptimizeState { ns :: Namespace
                                   , assumptions :: [(Namespace, [Assumption])]
                                   , inlines :: Inlines
                                   , env :: Inline }

data Optimizer a = Optimizer (OptimizeState -> (OptimizeState, a))

instance Monad Optimizer where

    fail   x = Optimizer (\y -> error x)
    return x = Optimizer (\y -> (y, x))

    Optimizer f >>= g =
        Optimizer (\x -> case f x of (y, x) -> let Optimizer gx = g x in gx y)

instance Functor Optimizer where

    fmap f (Optimizer g) = Optimizer (\x -> case g x of (y, x) -> (y, f x))

instance Applicative Optimizer where

    pure = return
    x <*> y = do f <- x
                 f <$> y

class Optimize a where

    optimize :: a -> Optimizer a

set_namespace :: Namespace -> Optimizer ()
set_namespace ns' = Optimizer (\x -> (x { ns = ns' }, ()))

get_namespace :: Optimizer Namespace
get_namespace  = Optimizer (\x -> (x, ns x))

set_inline :: Inlines -> Optimizer ()
set_inline ns' = Optimizer (\x -> (x { inlines = ns' }, ()))

get_inline :: Optimizer Inlines
get_inline  = Optimizer (\x -> (x, inlines x))

set_env :: Inline -> Optimizer ()
set_env ns' = Optimizer (\x -> (x { env = ns' }, ()))

get_env :: Optimizer Inline
get_env  = Optimizer (\x -> (x, env x))

with_env xs =

    do e <- get_env
       xs' <- xs
       set_env e
       return xs'

get_addr :: Addr a -> a
get_addr (Addr _ _ x) = x

instance (Optimize a) => Optimize (Addr a) where

    optimize (Addr s e a) = Addr s e <$> optimize a

instance Optimize (Expression Definition) where

    optimize (ApplyExpression f' @ (SymbolExpression f) args) =

        do is <- get_env
           case f `lookup` is of
             Nothing -> ApplyExpression <$> optimize f' <*> mapM optimize args
             Just (m, ex) ->

                 do args' <- mapM optimize args
                    return $ ApplyExpression (FunctionExpression [EqualityAxiom m (Addr undefined undefined ex)]) args'

    optimize (ApplyExpression f args) = ApplyExpression <$> optimize f <*> mapM optimize args
    optimize (IfExpression a b c) = IfExpression <$> optimize a <*> optimize b <*> optimize c
    optimize (LazyExpression x l) = flip LazyExpression l <$> optimize x
    optimize (FunctionExpression xs) = FunctionExpression <$> mapM optimize xs
    optimize (AccessorExpression x xs) = flip AccessorExpression xs <$> optimize x
    optimize (ListExpression ex) = ListExpression <$> mapM optimize ex

    optimize (LetExpression ds ex) =

        do ds' <- mapM optimize ds
           LetExpression ds' <$> optimize ex

    optimize (RecordExpression (M.toList -> xs)) =

        let (keys, vals) = unzip xs
        in  RecordExpression . M.fromList . zip keys <$> mapM optimize vals

    optimize x = return x


-- TODO wrong
instance Optimize (Match (Expression Definition)) where

    optimize x = return x

instance Optimize (Axiom (Expression Definition)) where

    optimize t @ (TypeAxiom _) = return t
    optimize (EqualityAxiom m ex) =

        do m <- optimize m
           ex <- optimize ex
           return (EqualityAxiom m ex)

instance Optimize Definition where

    optimize (Definition a True name [eq @ (EqualityAxiom _ _)]) =

        do (EqualityAxiom m ex) <- optimize eq
           is  <- get_inline
           e   <- get_env
           ns  <- get_namespace
           set_inline (((ns, name), (m, get_addr ex)) : is)
           set_env    ((name, (m, get_addr ex)) : e)
           return (Definition a True name [EqualityAxiom m ex])

    optimize (Definition a True c (TypeAxiom _ : x)) = optimize (Definition a True c x)
    optimize (Definition _ True name _) = fail$ "Illegal inline definition '" ++ show name ++ "'"

    optimize (Definition a b name xs) | is_recursive xs =

       do xs' <- mapM optimize xs
          return $ Definition a b name (to_trampoline xs')

       where is_recursive (TypeAxiom _: xs) = is_recursive xs
             is_recursive (EqualityAxiom _ x: xs) = is_recursive' (get_addr x) || is_recursive xs
             is_recursive [] = False

             is_recursive' (ApplyExpression (SymbolExpression x) args) | name == x = True
             is_recursive' (LetExpression _ e) = is_recursive' e
             is_recursive' (IfExpression _ a b) = is_recursive' a || is_recursive' b

             is_recursive' _ = False

             to_trampoline (t @ (TypeAxiom _): xs) = t : to_trampoline xs
             to_trampoline xs' =
                  [EqualityAxiom (Match [] Nothing) (Addr undefined undefined (JSExpression (g xs')))]

             g xs' = [jmacroE| (function() {
                                  var result = null;
                                  var f = `(to_trampoline' xs')`;
                                  return f;
                                  // while (result === null) {
                                  //     console.log("test");
                                  // }
                                })() |]


             -- expr [] = expr . J.scope $ []
             -- expr (TypeAxiom _:xs) = expr xs
             -- expr xs @ (EqualityAxiom (Match ps _) _ : _) = J.scope . J.curry (length ps) . toStat $ xs

--instance (Show a, ToJExpr a) => ToJExpr [Axiom a] where
                        
             to_trampoline' = id


             -- to_trampoline' (EqualityAxiom a x: xs) =

             --     (EqualityAxiom (fmap (to_trampoline'' a) x)) : to_trampoline' xs

             -- to_trampoline' [] = []

             -- to_trampoline'' (ApplyExpression (SymbolExpression x) args) | name == x = undefined

             -- LiteralExpression Literal
             -- SymbolExpression Symbol
             -- JSExpression JExpr
             -- LazyExpression (Addr (Expression d)) Lazy
             -- FunctionExpression [Axiom (Expression d)]
             -- RecordExpression (M.Map Symbol (Expression d))
             -- ListExpression [Expression d]
             -- AccessorExpression (Addr (Expression d)) [Symbol]

    optimize (Definition a b c xs) = Definition a b c <$> mapM optimize xs

instance Optimize Statement where

    optimize (DefinitionStatement d) = DefinitionStatement <$> optimize d
    optimize (ExpressionStatement (Addr s e x)) = ExpressionStatement . Addr s e <$> optimize x
    optimize (ModuleStatement x xs) =

        do ns <- get_namespace
           set_namespace$ ns `mappend` x
           xs' <- with_env$ optimize xs
           set_namespace ns
           return$ ModuleStatement x xs'

    optimize ss @ (ImportStatement (Namespace x)) =

        do is <- get_inline
           e  <- get_env
           n  <- get_namespace
           rfind n is e

        where rfind (Namespace n) is e =

                     case lookup' (Namespace x) is of
                       [] ->

                           if length n > 0 && head n /= head x
                           then do optimize (ImportStatement (Namespace (head n : x)))
                                   return ss
                           else return ss

                       (((_, s), ex): zs) ->

                           do set_env $ (s, ex) : e 
                              return ss

              lookup' x (((y, z), w):ys) | x == y = (((y, z), w) : lookup' x ys)
                                         | otherwise = lookup' x ys
              lookup' _ [] = []
                                         
    optimize x = return x

instance Optimize [Statement] where

    optimize [] = return []
    optimize (x:xs) =

        do x <- optimize x
           xs <- optimize xs
           return (x:xs)

instance Optimize Program where

    optimize (Program xs) = Program <$> optimize xs

run_optimizer :: Program -> [(Namespace, [Assumption])] -> Program
run_optimizer (optimize -> Optimizer f) as = case f gen_state of (_, p) -> p

    where gen_state = OptimizeState (Namespace []) as [] []
                       
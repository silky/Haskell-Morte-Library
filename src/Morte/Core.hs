{-# LANGUAGE OverloadedStrings, DeriveDataTypeable #-}
{-# OPTIONS_GHC -Wall #-}

{-| This module contains the core calculus for the Morte language.  This
    language is a minimalist implementation of the calculus of constructions,
    which is in turn a specific kind of pure type system.  If you are new to
    pure type systems you may wish to read \"Henk: a typed intermediate
    language\".

    <http://research.microsoft.com/en-us/um/people/simonpj/papers/henk.ps.gz>


    Morte is a strongly normalizing language, meaning that:

    * Every expression has a unique normal form computed by `normalize`

    * You test expressions for equality of their normal forms using `==`

    * Equational reasoning preserves normal forms


    Strong normalization comes at a price: Morte forbids recursion.  Instead,
    you must translate all recursion to F-algebras and translate all corecursion
    to F-coalgebras.  If you are new to F-(co)algebras then you may wish to read
    "Morte.Tutorial" or read \"Recursive types for free!\":

    <http://homepages.inf.ed.ac.uk/wadler/papers/free-rectypes/free-rectypes.txt>

    Morte is designed to be a super-optimizing intermediate language with a
    simple optimization scheme.  You optimize a Morte expression by just
    normalizing the expression.  If you normalize a long-lived program encoded
    as an F-coalgebra you typically get a state machine, and if you normalize a
    long-lived program encoded as an F-algebra you typically get an unrolled
    loop.

    Strong normalization guarantees that all abstractions encodable in Morte are
    \"free\", meaning that they may increase your program's compile times but
    they will never increase your program's run time because they will normalize
    to the same code.
-}

module Morte.Core (
    -- * Syntax
    Var(..),
    Const(..),
    Expr(..),
    Context,

    -- * Core functions
    typeWith,
    typeOf,
    normalize,

    -- * Utilities
    used,
    shift,
    prettyExpr,
    prettyTypeError,

    -- * Errors
    TypeError(..),
    TypeMessage(..),

    -- * Builders
    buildConst,
    buildVar,
    buildExpr,
    buildTypeMessage,
    buildTypeError,
    ) where

import Control.Applicative ((<$>), (<*>))
import Control.DeepSeq
import Control.Exception (Exception)
import Control.Monad.Trans.State (State, evalState)
import qualified Control.Monad.Trans.State as State
import Data.Binary (Binary(get, put), Get, Put)
import Data.Binary.Get (getWord64le)
import Data.Binary.Put (putWord64le)
import Data.Monoid (mempty, (<>))
import Data.String (IsString(fromString))
import Data.Text ()  -- For the `IsString` instance
import Data.Text.Lazy (Text, unpack)
import qualified Data.Text.Encoding as Text
import qualified Data.Text.Lazy as Text
import Data.Text.Lazy.Builder (Builder, toLazyText, fromLazyText)
import Data.Text.Lazy.Builder.Int (decimal)
import Data.Typeable (Typeable)
import Data.Word (Word8)

{-| Label for a bound variable

    The `Text` field is the variable's name (i.e. \"@x@\").

    The `Int` field disambiguates variables with the same name if there are
    multiple bound variables of the same name in scope.  Zero refers to the
    nearest bound variable and the index increases by one for each bound variable
    of the same name going outward.  The following diagram may help:

>                           +-refers to-+
>                           |           |
>                           v           |
> \(x : *) -> \(y : *) -> \(x : *) -> x@0
>
>   +-------------refers to-------------+
>   |                                   |
>   v                                   |
> \(x : *) -> \(y : *) -> \(x : *) -> x@1

    This `Int` behaves like a De Bruijn index in the special case where all
    variables have the same name.

    You can optionally omit the index if it is @0@:

>                           +refers to+
>                           |         |
>                           v         |
> \(x : *) -> \(y : *) -> \(x : *) -> x

    Zero indices are omitted when pretty-printing `Var`s and non-zero indices
    appear as a numeric suffix.
-}
data Var = V Text Int deriving (Eq, Show)

putUtf8 :: Text -> Put
putUtf8 txt = put (Text.encodeUtf8 (Text.toStrict txt))

getUtf8 :: Get Text
getUtf8 = do
    bs <- get
    case Text.decodeUtf8' bs of
        Left  e   -> fail (show e)
        Right txt -> return (Text.fromStrict txt)

instance Binary Var where
    put (V x n) = do
        putUtf8 x
        putWord64le (fromIntegral n)
    get = V <$> getUtf8 <*> fmap fromIntegral getWord64le

instance IsString Var
  where
    fromString str = V (Text.pack str) 0

instance NFData Var where
  rnf (V n p) = rnf n `seq` rnf p

{-| Constants for the calculus of constructions

    The only axiom is:

> ⊦ * : □

    ... and all four rule pairs are valid:

> ⊦ * ↝ * : *
> ⊦ □ ↝ * : *
> ⊦ * ↝ □ : □
> ⊦ □ ↝ □ : □

-}
data Const = Star | Box deriving (Eq, Show, Bounded, Enum)

instance Binary Const where
    put c = case c of
        Star -> put (0 :: Word8)
        Box  -> put (1 :: Word8)
    get = do
        n <- get :: Get Word8
        case n of
            0 -> return Star
            1 -> return Box
            _ -> fail "get Const: Invalid tag byte"

instance NFData Const

axiom :: Const -> Either TypeError Const
axiom Star = return Box
axiom Box  = Left (TypeError [] (Const Box) (Untyped Box))

rule :: Const -> Const -> Either TypeError Const
rule Star Box  = return Box
rule Star Star = return Star
rule Box  Box  = return Box
rule Box  Star = return Star

-- | Syntax tree for expressions
data Expr
    -- | > Const c        ~  c
    = Const Const
    -- | > Var (V x 0)    ~  x
    --   > Var (V x n)    ~  x@n
    | Var Var
    -- | > Lam x     A b  ~  λ(x : A) → b
    | Lam Text Expr Expr
    -- | > Pi x      A B  ~  ∀(x : A) → B
    --   > Pi unused A B  ~        A  → B
    | Pi  Text Expr Expr
    -- | > App f a        ~  f a
    | App Expr Expr
    deriving (Show)

lookupN :: Eq a => a -> [(a, b)] -> Int -> Maybe b
lookupN a ((a', b'):abs') n | a /= a'   = lookupN a abs'    n
                            | n >  0    = lookupN a abs' $! n - 1
                            | n == 0    = Just b'
                            | otherwise = Nothing
lookupN _  []             _             = Nothing

lookupCtx :: Var -> Context -> Maybe Expr
lookupCtx (V x n) ctx = lookupN x ctx n

instance Eq Expr where
    eL0 == eR0 = evalState (go (normalize eL0) (normalize eR0)) []
      where
        go :: Expr -> Expr -> State [(Text, Text)] Bool
        go (Const cL) (Const cR) = return (cL == cR)
        go (Var (V xL nL)) (Var (V xR nR)) = do
            ctx <- State.get
            return (nL == nR && case lookupN xL ctx nL of
                    Nothing  -> xL  == xR
                    Just xR' -> xR' == xR )
        go (Lam xL tL bL) (Lam xR tR bR) = do
            ctx <- State.get
            State.put ((xL, xR):ctx)
            eq1 <- go tL tR
            eq2 <- go bL bR
            State.put ctx
            return (eq1 && eq2)
        go (Pi xL tL bL) (Pi xR tR bR) = do
            ctx <- State.get
            State.put ((xL, xR):ctx)
            eq1 <- go tL tR
            eq2 <- go bL bR
            State.put ctx
            return (eq1 && eq2)
        go (App fL aL) (App fR aR) = do
            b1 <- go fL fR
            b2 <- go aL aR
            return (b1 && b2)
        go _ _ = return False

instance Binary Expr where
    put e = case e of
        Const c    -> do
            put (0 :: Word8)
            put c
        Var x      -> do
            put (1 :: Word8)
            put x
        Lam x _A b -> do
            put (2 :: Word8)
            putUtf8 x
            put _A
            put b
        Pi  x _A _B -> do
            put (3 :: Word8)
            putUtf8 x
            put _A
            put _B
        App f a     -> do
            put (4 :: Word8)
            put f
            put a

    get = do
        n <- get :: Get Word8
        case n of
            0 -> Const <$> get
            1 -> Var <$> get
            2 -> Lam <$> getUtf8 <*> get <*> get
            3 -> Pi  <$> getUtf8 <*> get <*> get
            4 -> App <$> get <*> get
            _ -> fail "get Expr: Invalid tag byte"

instance IsString Expr
  where
    fromString str = Var (fromString str)

instance NFData Expr where
    rnf e = case e of
        Const c     -> rnf c
        Var   v     -> rnf v
        Lam x _A b  -> rnf x `seq` rnf _A `seq` rnf b
        Pi  x _A _B -> rnf x `seq` rnf _A `seq` rnf _B
        App f a     -> rnf f `seq` rnf a

{-| Bound variable names and their types

    Variable names may appear more than once in the `Context`.  The `Var` @x\@n@
    refers to the @n@th occurrence of @x@ in the `Context` (using 0-based
    numbering).
-}
type Context = [(Text, Expr)]

-- | The specific type error
data TypeMessage
    = UnboundVariable
    | InvalidInputType Expr
    | InvalidOutputType Expr
    | NotAFunction
    | TypeMismatch Expr Expr
    | Untyped Const
    deriving (Show)

instance NFData TypeMessage where
    rnf tm = case tm of
        UnboundVariable     -> ()
        InvalidInputType e  -> rnf e
        InvalidOutputType e -> rnf e
        NotAFunction        -> ()
        TypeMismatch e1 e2  -> rnf e1 `seq` rnf e2
        Untyped c           -> rnf c

-- | A structured type error that includes context
data TypeError = TypeError
    { context     :: Context
    , current     :: Expr
    , typeMessage :: TypeMessage
    } deriving (Typeable)

instance Show TypeError where
    show = unpack . prettyTypeError

instance Exception TypeError

instance NFData TypeError where
    rnf (TypeError ctx crr tym) = rnf ctx `seq` rnf crr `seq` rnf tym

-- | Render a pretty-printed `Const` as a `Builder`
buildConst :: Const -> Builder
buildConst c = case c of
    Star -> "*"
    Box  -> "□"

-- | Render a pretty-printed `Var` as a `Builder`
buildVar :: Var -> Builder
buildVar (V txt n) =
    fromLazyText txt <> if n == 0 then mempty else "@" <> decimal n

-- | Render a pretty-printed `Expr` as a `Builder`
buildExpr :: Expr -> Builder
buildExpr = go False False
  where
    go :: Bool -> Bool -> Expr -> Builder
    go parenBind parenApp e = case e of
        Const c    -> buildConst c
        Var x      -> buildVar x
        Lam x _A b ->
                (if parenBind then "(" else "")
            <>  "λ("
            <>  fromLazyText x
            <>  " : "
            <>  go False False _A
            <>  ") → "
            <>  go False False b
            <>  (if parenBind then ")" else "")
        Pi  x _A b ->
                (if parenBind then "(" else "")
            <>  (if used x b
                 then
                     "∀(" <> fromLazyText x <> " : " <> go False False _A <> ")"
                 else go True False _A )
            <>  " → "
            <>  go False False b
            <>  (if parenBind then ")" else "")
        App f a    ->
                (if parenApp then "(" else "")
            <>  go True False f <> " " <> go True True a
            <>  (if parenApp then ")" else "")

{-| Determine whether a `Pi`-bound variable should be displayed

    Notice that if any variable within the body of a `Pi` shares the same name and
    an equal or greater DeBruijn index we display the `Pi`-bound variable.  To
    illustrate why we don't just check for equality, consider this type:

    > forall (a : *) -> forall (a : *) -> a@1

    The @a\@1@ refers to the outer @a@ (i.e. the left one), but if we hid the
    inner @a@ (the right one), the type would make no sense:

    > forall (a : *) -> * -> a@1

    ... because the @a\@1@ would misleadingly appear to be an unbound variable.
-}
used :: Text -> Expr -> Bool
used x e0 = go e0 0
  where
    go e n = case e of
        Var (V x' n') | x == x' && n' >= n -> True
                      | otherwise          -> False
        Lam x'  _A  b             -> go _A n || (go  b $! n')
          where
            n' = if x == x' then n + 1 else n
        Pi  x'  _A _B             -> go _A n || (go _B $! n')
          where
            n' = if x == x' then n + 1 else n
        App f a                  -> go f n || go a n
        Const _                  -> False

-- | Render a pretty-printed `TypeMessage` as a `Builder`
buildTypeMessage :: TypeMessage -> Builder
buildTypeMessage msg = case msg of
    UnboundVariable          ->
            "Error: Unbound variable\n"
    InvalidInputType expr    ->
            "Error: Invalid input type\n"
        <>  "\n"
        <>  "Type: " <> buildExpr expr <> "\n"
    InvalidOutputType expr   ->
            "Error: Invalid output type\n"
        <>  "\n"
        <>  "Type: " <> buildExpr expr <> "\n"
    NotAFunction             ->
            "Error: Only functions may be applied to values\n"
    TypeMismatch expr1 expr2 ->
            "Error: Function applied to argument of the wrong type\n"
        <>  "\n"
        <>  "Expected type: " <> buildExpr expr1 <> "\n"
        <>  "Argument type: " <> buildExpr expr2 <> "\n"
    Untyped c                ->
            "Error: " <> buildConst c <> " has no type\n"

-- | Render a pretty-printed `TypeError` as a `Builder`
buildTypeError :: TypeError -> Builder
buildTypeError (TypeError ctx expr msg)
    =   "\n"
    <>  (    if Text.null (toLazyText buildContext )
             then mempty
             else "Context:\n" <> buildContext <> "\n"
        )
    <>  "Expression: " <> buildExpr expr <> "\n"
    <>  "\n"
    <>  buildTypeMessage msg
  where
    buildKV (key, val) = fromLazyText key <> " : " <> buildExpr val

    buildContext =
        (fromLazyText . Text.unlines . map (toLazyText . buildKV) . reverse) ctx


{-| Substitute all occurrences of a variable with an expression

> subst x n C B  ~  B[x@n := C]
-}
subst :: Text -> Int -> Expr -> Expr -> Expr
subst x n e' e = case e of
    Lam x' _A  b  -> Lam x' (subst x n e' _A)  b'
      where
        n'  = if x == x' then n + 1 else n
        b'  = n' `seq` subst x n' (shift 1 x' e')  b
    Pi  x' _A _B  -> Pi  x' (subst x n e' _A) _B'
      where
        n'  = if x == x' then n + 1 else n
        _B' = n' `seq` subst x n' (shift 1 x' e') _B
    App f a       -> App (subst x n e' f) (subst x n e' a)
    Var (V x' n') -> if x == x' && n == n' then e' else e
    Const k       -> Const k

{-| @shift n x@ adds @n@ to the index of all free variables named @x@ within an
    `Expr`
-}
shift :: Int -> Text -> Expr -> Expr
shift d x0 e0 = go e0 0
  where
    go e c = case e of
        Lam x _A  b  -> Lam x (go _A c) (go  b $! c')
          where
            c' = if x == x0 then c + 1 else c
        Pi  x _A _B  -> Pi  x (go _A c) (go _B $! c')
          where
            c' = if x == x0 then c + 1 else c
        App f a       -> App (go f c) (go a c)
        Var (V x n) -> n' `seq` Var (V x n')
          where
            n' = if x == x0 && n >= c then n + d else n
        Const k       -> Const k

{-| Type-check an expression and return the expression's type if type-checking
    suceeds or an error if type-checking fails

    `typeWith` does not necessarily normalize the type since full normalization
    is not necessary for just type-checking.  If you actually care about the
    returned type then you may want to `normalize` it afterwards.
-}
typeWith :: Context -> Expr -> Either TypeError Expr
typeWith ctx e = case e of
    Const c     -> fmap Const (axiom c)
    Var x       -> case lookupCtx x ctx of
        Nothing -> Left (TypeError ctx e UnboundVariable)
        Just a  -> return a
    Lam x _A b  -> do
        let ctx' = [ (x', shift 1 x _A') | (x', _A') <- (x, _A):ctx ]
        _B <- typeWith ctx' b
        let p = Pi x _A _B
        _t <- typeWith ctx p
        return p
    Pi  x _A _B -> do
        eS <- fmap whnf (typeWith ctx _A)
        s  <- case eS of
            Const s -> return s
            _       -> Left (TypeError ctx e (InvalidInputType _A))
        let ctx' = [ (x', shift 1 x _A') | (x', _A') <- (x, _A):ctx ]
        eT <- fmap whnf (typeWith ctx' _B)
        t  <- case eT of
            Const t -> return t
            _       -> Left (TypeError ctx' e (InvalidOutputType _B))
        fmap Const (rule s t)
    App f a     -> do
        e' <- fmap whnf (typeWith ctx f)
        (x, _A, _B) <- case e' of
            Pi x _A _B -> return (x, _A, _B)
            _          -> Left (TypeError ctx e NotAFunction)
        _A' <- typeWith ctx a
        if _A == _A'
            then do
                let a'  = shift 1 x a
                    _B' = subst x 0 a' _B
                return (shift (-1) x _B')
            else do
                let nf_A  = normalize _A
                    nf_A' = normalize _A'
                Left (TypeError ctx e (TypeMismatch nf_A nf_A'))

{-| `typeOf` is the same as `typeWith` with an empty context, meaning that the
    expression must be closed (i.e. no free variables), otherwise type-checking
    will fail.
-}
typeOf :: Expr -> Either TypeError Expr
typeOf = typeWith []

-- | Reduce an expression to weak-head normal form
whnf :: Expr -> Expr
whnf e = case e of
    App f a -> case whnf f of
        Lam x _A b -> whnf (shift (-1) x b')  -- Beta reduce
          where
            a' = shift 1 x a
            b' = subst x 0 a' b
        _          -> e
    _       -> e

-- | Returns whether a variable is free in an expression
freeIn :: Var -> Expr -> Bool
freeIn v@(V x n) = go
  where
    go e = case e of
        Lam x' _A b  ->
            n' `seq` (go _A || if x == x' then freeIn (V x n')  b else go  b)
          where
            n' = n + 1
        Pi  x' _A _B ->
            n' `seq` (go _A || if x == x' then freeIn (V x n') _B else go _B)
          where
            n' = n + 1
        Var v'      -> v == v'
        App f a     -> go f || go a
        Const _     -> False

{-| Reduce an expression to its normal form, performing both beta reduction and
    eta reduction

    `normalize` does not type-check the expression.  You may want to type-check
    expressions before normalizing them since normalization can convert an
    ill-typed expression into a well-typed expression.
-}
normalize :: Expr -> Expr
normalize e = case e of
    Lam x _A b -> case b' of
        App f a -> case a of
            Var v' | v == v' && not (v `freeIn` f) ->
                shift (-1) x f  -- Eta reduce
                   | otherwise                     ->
                e'
              where
                v = V x 0
            _                                      -> e'
        _       -> e'
      where
        b' = normalize b
        e' = Lam x (normalize _A) b'
    Pi  x _A _B -> Pi x (normalize _A) (normalize _B)
    App f a     -> case normalize f of
        Lam x _A b -> normalize (shift (-1) x b')  -- Beta reduce
          where
            a' = shift 1 x a
            b' = subst x 0 a' b
        f'         -> App f' (normalize a)
    Var   _    -> e
    Const _    -> e

{-| Pretty-print an expression

    The result is a syntactically valid Morte program
-}
prettyExpr :: Expr -> Text
prettyExpr = toLazyText . buildExpr

-- | Pretty-print a type error
prettyTypeError :: TypeError -> Text
prettyTypeError = toLazyText . buildTypeError

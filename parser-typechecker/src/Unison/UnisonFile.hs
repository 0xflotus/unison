{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE PatternSynonyms #-}

module Unison.UnisonFile where

import Unison.Prelude

import Control.Lens
import           Data.Bifunctor         (second)
import qualified Data.Map               as Map
import qualified Data.Set               as Set
import qualified Unison.ABT as ABT
import qualified Unison.ConstructorType as CT
import           Unison.DataDeclaration (DataDeclaration')
import           Unison.DataDeclaration (EffectDeclaration' (..))
import           Unison.DataDeclaration (hashDecls, toDataDecl)
import qualified Unison.DataDeclaration as DD
import qualified Unison.Name            as Name
import qualified Unison.Names3          as Names
import           Unison.Reference       (Reference)
import           Unison.Referent        (Referent)
import qualified Unison.Referent        as Referent
import           Unison.Term            (AnnotatedTerm)
import qualified Unison.Term            as Term
import           Unison.Type            (Type)
import qualified Unison.Type            as Type
import qualified Unison.Util.List       as List
import           Unison.Util.Relation   (Relation)
import qualified Unison.Util.Relation   as Relation
import           Unison.Var             (Var)
import qualified Unison.Var             as Var
import qualified Unison.Typechecker.TypeLookup as TL
import Unison.Names3 (Names0)
import qualified Unison.LabeledDependency as LD
import Unison.LabeledDependency (LabeledDependency)

data UnisonFile v a = UnisonFile {
  dataDeclarations   :: Map v (Reference, DataDeclaration' v a),
  effectDeclarations :: Map v (Reference, EffectDeclaration' v a),
  terms :: [(v, AnnotatedTerm v a)],
  watches :: Map WatchKind [(v, AnnotatedTerm v a)]
} deriving Show

watchesOfKind :: WatchKind -> UnisonFile v a -> [(v, AnnotatedTerm v a)]
watchesOfKind kind uf = Map.findWithDefault [] kind (watches uf)

watchesOfOtherKinds :: WatchKind -> UnisonFile v a -> [(v, AnnotatedTerm v a)]
watchesOfOtherKinds kind uf =
  join [ ws | (k, ws) <- Map.toList (watches uf), k /= kind ]

allWatches :: UnisonFile v a -> [(v, AnnotatedTerm v a)]
allWatches = join . Map.elems . watches

type WatchKind = Var.WatchKind
pattern RegularWatch = Var.RegularWatch
pattern TestWatch = Var.TestWatch

-- Converts a file to a single let rec with a body of `()`, for
-- purposes of typechecking.
typecheckingTerm :: (Var v, Monoid a) => UnisonFile v a -> AnnotatedTerm v a
typecheckingTerm uf =
  Term.letRec' True (terms uf <> testWatches <> watchesOfOtherKinds TestWatch uf) $
  DD.unitTerm mempty
  where
    -- we make sure each test has type Test.Result
    f w = let wa = ABT.annotation w in Term.ann wa w (DD.testResultType wa)
    testWatches = map (second f) $ watchesOfKind TestWatch uf

-- Converts a file and a body to a single let rec with the given body.
uberTerm' :: (Var v, Monoid a) => UnisonFile v a -> AnnotatedTerm v a -> AnnotatedTerm v a
uberTerm' uf body =
  Term.letRec' True (terms uf <> allWatches uf) $ body

-- A UnisonFile after typechecking. Terms are split into groups by
-- cycle and the type of each term is known.
data TypecheckedUnisonFile v a =
  TypecheckedUnisonFile {
    dataDeclarations'   :: Map v (Reference, DataDeclaration' v a),
    effectDeclarations' :: Map v (Reference, EffectDeclaration' v a),
    topLevelComponents' :: [[(v, AnnotatedTerm v a, Type v a)]],
    watchComponents     :: [(WatchKind, [(v, AnnotatedTerm v a, Type v a)])],
    hashTerms           :: Map v (Reference, AnnotatedTerm v a, Type v a)
  } deriving Show

typecheckedUnisonFile :: Var v
                      => Map v (Reference, DataDeclaration' v a)
                      -> Map v (Reference, EffectDeclaration' v a)
                      -> [[(v, AnnotatedTerm v a, Type v a)]]
                      -> [(WatchKind, [(v, AnnotatedTerm v a, Type v a)])]
                      -> TypecheckedUnisonFile v a
typecheckedUnisonFile datas effects tlcs watches =
  file0 { hashTerms = hashImpl file0 }
  where
  file0 = TypecheckedUnisonFile datas effects tlcs watches mempty
  hashImpl file = let
    -- test watches are added to the codebase also
    -- todo: maybe other kinds of watches too
    components = topLevelComponents file
    types = Map.fromList [(v,t) | (v,_,t) <- join components ]
    terms0 = Map.fromList [(v,e) | (v,e,_) <- join components ]
    hcs = Term.hashComponents terms0
    in Map.fromList [ (v, (r, e, t)) | (v, (r, e)) <- Map.toList hcs,
                                       Just t <- [Map.lookup v types] ]

lookupDecl :: Ord v => v -> TypecheckedUnisonFile v a
           -> Maybe (Reference, Either (EffectDeclaration' v a) (DataDeclaration' v a))
lookupDecl v uf =
  over _2 Right <$> (Map.lookup v (dataDeclarations' uf)  ) <|>
  over _2 Left  <$> (Map.lookup v (effectDeclarations' uf))

allTerms :: Ord v => TypecheckedUnisonFile v a -> Map v (AnnotatedTerm v a)
allTerms uf =
  Map.fromList [ (v, t) | (v, t, _) <- join $ topLevelComponents' uf ]

topLevelComponents :: TypecheckedUnisonFile v a
                   -> [[(v, AnnotatedTerm v a, Type v a)]]
topLevelComponents file =
  topLevelComponents' file ++ [ comp | (TestWatch, comp) <- watchComponents file ]

getDecl' :: Ord v => TypecheckedUnisonFile v a -> v -> Maybe (DD.Decl v a)
getDecl' uf v =
  (Right . snd <$> Map.lookup v (dataDeclarations' uf)) <|>
  (Left . snd <$> Map.lookup v (effectDeclarations' uf))

-- External type references that appear in the types of the file's terms
termSignatureExternalLabeledDependencies
  :: Ord v => TypecheckedUnisonFile v a -> Set LabeledDependency
termSignatureExternalLabeledDependencies TypecheckedUnisonFile{..} =
  Set.difference
    (Set.map LD.typeRef
      . foldMap Type.dependencies
      . fmap (\(_r, _e, t) -> t)
      . toList
      $ hashTerms)
    -- exclude any references that are defined in this file
    (Set.fromList $
      (map (LD.typeRef . fst) . toList) dataDeclarations' <>
      (map (LD.typeRef . fst) . toList) effectDeclarations')

-- Returns a relation for the dependencies of this file. The domain is
-- the dependent, and the range is its dependencies, thus:
-- `R.lookupDom r (dependencies file)` returns the set of dependencies
-- of the reference `r`.
dependencies' ::
  forall v a. Var v => TypecheckedUnisonFile v a -> Relation Reference Reference
dependencies' file = let
  terms :: Map v (Reference, AnnotatedTerm v a, Type v a)
  terms = hashTerms file
  decls :: Map v (Reference, DataDeclaration' v a)
  decls = dataDeclarations' file <>
          fmap (second toDataDecl) (effectDeclarations' file )
  termDeps = foldl' f Relation.empty $ toList terms
  allDeps = foldl' g termDeps $ toList decls
  f acc (r, tm, tp) = acc <> termDeps <> typeDeps
    where termDeps =
            Relation.fromList [ (r, dep) | dep <- toList (Term.dependencies tm)]
          typeDeps =
            Relation.fromList [ (r, dep) | dep <- toList (Type.dependencies tp)]
  g acc (r, decl) = acc <> ctorDeps
    where ctorDeps =
            Relation.fromList [ (r, dep) | (_, _, tp) <- DD.constructors' decl
                                         , dep <- toList (Type.dependencies tp)
                                         ]
  in allDeps

-- Returns the dependencies of the `UnisonFile` input. Needed so we can
-- load information about these dependencies before starting typechecking.
dependencies :: (Monoid a, Var v) => UnisonFile v a -> Set Reference
dependencies uf = Term.dependencies (typecheckingTerm uf)

discardTypes :: TypecheckedUnisonFile v a -> UnisonFile v a
discardTypes (TypecheckedUnisonFile datas effects terms watches _) = let
  watches' = g . mconcat <$> List.multimap watches
  g tup3s = [(v,e) | (v,e,_t) <- tup3s ]
  in UnisonFile datas effects [ (a,b) | (a,b,_) <- join terms ] watches'

declsToTypeLookup :: Var v => UnisonFile v a -> TL.TypeLookup v a
declsToTypeLookup uf = TL.TypeLookup mempty
                          (wrangle (dataDeclarations uf))
                          (wrangle (effectDeclarations uf))
  where wrangle = Map.fromList . Map.elems

toNames :: Var v => UnisonFile v a -> Names0
toNames (UnisonFile {..}) = datas <> effects
  where
    datas = foldMap DD.dataDeclToNames' (Map.toList dataDeclarations)
    effects = foldMap DD.effectDeclToNames' (Map.toList effectDeclarations)

typecheckedToNames0 :: Var v => TypecheckedUnisonFile v a -> Names0
typecheckedToNames0 uf = Names.names0 (terms <> ctors) types where
  terms = Relation.fromList
    [ (Name.fromVar v, Referent.Ref r)
    | (v, (r, _, _)) <- Map.toList $ hashTerms uf ]
  types = Relation.fromList
    [ (Name.fromVar v, r)
    | (v, r) <- Map.toList $ fmap fst (dataDeclarations' uf)
                          <> fmap fst (effectDeclarations' uf) ]
  ctors = Relation.fromMap . Map.mapKeys Name.fromVar . hashConstructors $ uf

typecheckedUnisonFile0 :: Ord v => TypecheckedUnisonFile v a
typecheckedUnisonFile0 = TypecheckedUnisonFile Map.empty Map.empty mempty mempty mempty

-- Returns true if the file has any definitions or watches
nonEmpty :: TypecheckedUnisonFile v a -> Bool
nonEmpty uf =
  not (Map.null (dataDeclarations' uf)) ||
  not (Map.null (effectDeclarations' uf)) ||
  any (not . null) (topLevelComponents' uf) ||
  any (not . null) (watchComponents uf)

hashConstructors
  :: forall v a. Ord v => TypecheckedUnisonFile v a -> Map v Referent
hashConstructors file =
  let ctors1 = Map.elems (dataDeclarations' file) >>= \(ref, dd) ->
        [ (v, Referent.Con ref i CT.Data) | (v,i) <- DD.constructorVars dd `zip` [0 ..] ]
      ctors2 = Map.elems (effectDeclarations' file) >>= \(ref, dd) ->
        [ (v, Referent.Con ref i CT.Effect) | (v,i) <- DD.constructorVars (DD.toDataDecl dd) `zip` [0 ..] ]
  in Map.fromList (ctors1 ++ ctors2)

type CtorLookup = Map String (Reference, Int)

-- Substitutes free type and term variables occurring in the terms of this
-- `UnisonFile` using `externalNames`.
--
-- Hash-qualified names are substituted during parsing, but non-HQ names are
-- substituted at the end of parsing, since they can be locally bound. Example, in
-- `x -> x + math.sqrt 2`, we don't know if `math.sqrt` is locally bound until
-- we are done parsing, whereas `math.sqrt#abc` can be resolved immediately
-- as it can't refer to a local definition.
bindNames :: Var v
          => Names0
          -> UnisonFile v a
          -> Names.ResolutionResult v a (UnisonFile v a)
bindNames names (UnisonFile d e ts ws) = do
  -- todo: consider having some kind of binding structure for terms & watches
  --    so that you don't weirdly have free vars to tiptoe around.
  --    The free vars should just be the things that need to be bound externally.
  let termVars = (fst <$> ts) ++ (Map.elems ws >>= map fst)
      termVarsSet = Set.fromList termVars
  -- todo: can we clean up this lambda using something like `second`
  ts' <- traverse (\(v,t) -> (v,) <$> Term.bindNames termVarsSet names t) ts
  ws' <- traverse (traverse (\(v,t) -> (v,) <$> Term.bindNames termVarsSet names t)) ws
  pure $ UnisonFile d e ts' ws'

constructorType ::
  Var v => UnisonFile v a -> Reference -> Maybe CT.ConstructorType
constructorType = TL.constructorType . declsToTypeLookup

data Env v a = Env
  -- Data declaration name to hash and its fully resolved form
  { datas   :: Map v (Reference, DataDeclaration' v a)
  -- Effect declaration name to hash and its fully resolved form
  , effects :: Map v (Reference, EffectDeclaration' v a)
  -- Naming environment
  , names   :: Names0
}

data Error v a
  -- A free type variable that couldn't be resolved
  = UnknownType v a
  -- A variable which is both a data and an ability declaration
  | DupDataAndAbility v a a
  deriving (Eq,Ord,Show)

-- This function computes hashes for data and effect declarations, and
-- also returns a function for resolving strings to (Reference, ConstructorId)
-- for parsing of pattern matching
--
-- If there are duplicate declarations, the duplicated names are returned on the
-- left.
environmentFor
  :: forall v a . Var v
  => Names0
  -> Map v (DataDeclaration' v a)
  -> Map v (EffectDeclaration' v a)
  -> Names.ResolutionResult v a (Either [Error v a] (Env v a))
environmentFor names dataDecls0 effectDecls0 = do
  let locallyBoundTypes = Map.keysSet dataDecls0 <> Map.keysSet effectDecls0
  -- data decls and hash decls may reference each other, and thus must be hashed together
  dataDecls :: Map v (DataDeclaration' v a) <-
    traverse (DD.bindNames locallyBoundTypes names) dataDecls0
  effectDecls :: Map v (EffectDeclaration' v a) <-
    traverse (DD.withEffectDeclM (DD.bindNames locallyBoundTypes names)) effectDecls0
  let allDecls0 :: Map v (DataDeclaration' v a)
      allDecls0 = Map.union dataDecls (toDataDecl <$> effectDecls)
  hashDecls' :: [(v, Reference, DataDeclaration' v a)] <-
      hashDecls allDecls0
    -- then we have to pick out the dataDecls from the effectDecls
  let
    allDecls   = Map.fromList [ (v, (r, de)) | (v, r, de) <- hashDecls' ]
    dataDecls' = Map.difference allDecls effectDecls
    effectDecls' = second EffectDeclaration <$> Map.difference allDecls dataDecls
    -- ctor and effect terms
    ctors = foldMap DD.dataDeclToNames' (Map.toList dataDecls')
    effects = foldMap DD.effectDeclToNames' (Map.toList effectDecls')
    names' = ctors <> effects
    overlaps = let
      w v dd (toDataDecl -> ed) = DupDataAndAbility v (DD.annotation dd) (DD.annotation ed)
      in Map.elems $ Map.intersectionWithKey w dataDecls effectDecls where
    okVars = Map.keysSet allDecls0
    unknownTypeRefs = Map.elems allDecls0 >>= \dd ->
      let cts = DD.constructorTypes dd
      in cts >>= \ct -> [ UnknownType v a | (v,a) <- ABT.freeVarOccurrences mempty ct
                                          , not (Set.member v okVars) ]
  pure $
    if null overlaps && null unknownTypeRefs
    then pure $ Env dataDecls' effectDecls' names'
    else Left (unknownTypeRefs ++ overlaps)

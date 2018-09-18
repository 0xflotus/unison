Note: initial draft, probably a lot of rough edges. Comments/questions/ideas are welcome!

# Editing a Unison codebase

The Unison codebase is not just a mutable bag of text files, it's a structured object that undergoes a series of well-typed transformations over the course of development, yet we can still make arbitrary edits to a codebase. The benefits of the Unison approach which we'll see are:

* Incremental compilation is perfectly precise and comes for free, regardless of what editor you use. You'll almost never spend time [waiting for Unison code to compile](https://xkcd.com/303/), _no matter how large your codebase_.
* Refactoring is a controlled experience where the refactoring always typechecks and you can precisely measure your progress, so arbitrary changes to a codebase can be completed without ever dealing with a depressingly long list of (often misleading) compile errors or broken tests!
* Codebase changes can be worked on concurrently by multiple developers, and many situations that traditionally result in incidental merge conflicts or build issues can no longer occur. (e.g., Alice swapped the order of two definitions in a file, conflicting with Bob's adding an unrelated definition.)
* Renames, even bulk renames of whole packages of definitions, are 100% accurate and fast. When it's this easy to rename things, there's less anxiety about picking names and less need to pick the perfect name at the moment you start writing something.
* We can assign multiple names to the same definitions, and you can choose which naming you prefer and publish your naming schemes for others to use if they wish. [Bikeshedding](http://bikeshed.com/) over names can be a thing of the past (or at least vastly reduced 😀).
* Dependency hell is also vastly reduced: many situations that contribute to dependency hell simply cannot arise with the Unison codebase model.
* As an added bonus, it's no problem to use different versions of some library in different parts of your application when convenient, just as you might use two unrelated libraries in your application.
* It's easy to mix and match parts of different libraries into a custom bundle, which others can use, all while retaining full compatibility with the existing libraries that the bundle draws from.
* Publishing code is trivial; it won't require any additional steps beyond pushing to a git repository or shared filesystem. (Other filesystem-like services can be supported in the future.)
* Import statements are first-class values which can be shared and aggregated and published for consumption by others. No more project-wide import boilerplate at the top of every file!
* And this is all done in a backwards compatible way using existing tools: you can still use your favorite text editor, can still version your code with Git, use GitHub, etc.

Warning: once you experience this mode of editing a codebase and the control, safety, and ease of it, the "mutable bag of text files" model of a codebase may start to seem barbaric in comparison. 😱

## The big idea  🧠

Here it is: _Unison definitions are identified by content._ Therefore, there's no such thing as changing a definition, there's only introducing new definitions.  What can change is how we map definitions to human-friendly names. e.g. `x -> x + 1` (a definition) vs `Integer.increment` (a name we associate with it for the purposes of writing and reading other code that references it). An analogy: Unison definitions are like stars in the sky. We can discover new stars and create new star maps that pick different names for the stars, but the stars exist independently of what we choose to call them.

With this model, we don't ever change a definition, nor do we ever change the mapping from names to definitions (we call such mappings "namespaces"). A namespace is simply another kind of definition. Like all definitions, it is immutable. When we want to "change" a namespace, we create a new one, and _change which namespace mapping we are interested in_. This might seem limited, but it isn't at all, as we'll see.

From this simple idea of making definitions (including definitions of namespaces) immutable, we can build a better development experience around codebase editing with all of the above benefits.

## The model

This section gives the model of what a Unison codebase is and gives its API. Later we'll cover what the actual user experience is for interacting with the model, along with various concrete usage scenarios. The model deals with a few types, `Code`, `Codebase`, `Release`, and `Branch`:

* `Code` could be a function or value definition (a `Term`) or a `TypeDeclaration`. Each `Term` in the `Codebase` also includes its `Type`. A Unison codebase contains no ill-typed terms. Each `Code` also knows its `Author` and `License`, which are just terms.
* `Namespace` denotes a `Map Name Code`. It defines a subset of the universe of possible Unison definitions, along with names for these definitions. (The set of definitions is just the set of values of this `Map`.)
* `Release` denotes a `(Namespace, Namespace -> Namespace)`. It exposes a namespace and also provides a function for "upgrading" from old definitions.
* `Branch` denotes a function `Release -> Release`: it moves us from one release to another. Importantly, branches come with a commutative merge function, so they can be used to combine concurrent edits.
* `Codebase` denotes a `Set Code`, a `Map Name Branch` of named branches, and a `Map Name Release` of named releases.

Here's `Codebase` and `Code` types:

```haskell
data Codebase =
  Codebase { code     : Set Code
           , branches : Map Name Branch
           , tags     : Map Name Release }

-- All code knows its dependencies, author, and license
Code.dependencies : Code -> Set Code
Code.author : Code -> Author
Code.license : Code -> License
```

Here's `Branch` and `Release`:

```haskell
-- A branch can have unresolved conflicts, and we maintain some
-- history to help merge branches, respecting causality
data Branch = Branch
  { namespace   :: Map Name (Causal NameEdits)
  , edited      :: Map Term (Causal (Conflicted Edit))
  , editedTypes :: Map TypeDeclaration (Causal (Conflicted TypeEdit)) }

-- A release doesn't have history or conflicts.
data Release = Release
  { namespace   :: Map Name Code
  , edited      :: Map Term Edit
  , editedTypes :: Map TypeDeclaration TypeEdit }

data Conflicted a = One a | Many (Set a)

instance Eq a => Semigroup (Conflicted a) where
  One a <> One a2 = if a == a2 then One a else Many (Set.fromList [a,a2])
  One a <> Many as = Many (Set.add a as)
  Many as <> One a = Many (Set.add a as)
  Many as <> Many as2 = Many (as `Set.union` as2)

data Edit     = Replace Term Typing     | Deprecated | .. -- SwapArguments Permutation, etc
data TypeEdit = Replace TypeDeclaration | Deprecated
data NameEdits = NameEdits { adds :: Set Code, removes :: Set Code }
data Typing = Same | Subtype | Different

merge :: Branch -> Branch -> Branch
merge b1 b2 = let
  edited'      = Map.unionWith mappend (edited b1) (edited b2)
  editedTypes' = Map.unionWith mappend (editedTypes b1) (editedTypes b2)
  namespace'   = Map.unionWith mappend (namespace b1) (namespace b2)
  in Branch version' edited' namespace'

-- produces a release if the branch is not conflicted
Branch.toRelease :: Branch -> Either Conflicts Release
Release.toBranch :: Release -> Branch
Release.toBranch = ... -- trivial, just promoting a to `Causal (Conflicted a)`

-- common workflow - grabbing a release, then applying it to a branch you
-- have in progress
-- todo: do you want to republish the names for releases you are merging in?
-- I'm guessing yeah, but perhaps under a prefix, and perhaps just for the
-- subset of functions you are actually using in your branch...
-- or perhaps you do this pruning when you go to do a release
```

A couple notes:

* The `Typing` indicates whether the replacement `Code` is the same type as the old `Code`, a subtype of it, or a different type. This is useful for knowing how far we can automatically changes in a `Branch`.
* The `Edit` type produces a `Conflict` when merged, though with more structured edits (*e.g.*, in the case of the `SwapArguments` data constructor), even more could be done here.

Here's the `Causal` type, which is used above in `Branch`:

```haskell
newtype Causal e = Causal { get :: e, history :: History e }

data History e
  = Zero { currentHash :: Hash }
  | One { edit :: e, previous :: History e, currentHash :: Hash }
  | Merge { previous1 :: History e, previous2 :: History e, currentHash :: Hash }

instance Semigroup e => Semigroup (Causal e) where
  Causal a1 h1 <> Causal a2 h2
    | before h1 h2 = Causal a2 h2
    | before h2 h1 = Causal a1 h1
    | otherwise    = Causal (a1 <> a2) (h1 `merge` h2)

one :: Hashable e => e -> History e -> History e
one e h = One e h (hash e <> previousHash h)

merge :: Hashable e => History e -> History e -> History e
merge h1 h2 | h1 `before` h2 = h2
            | h2 `before` h1 = h1
            | otherwise      = Merge h1 h2 (currentHash h1 <> currentHash h2)

-- Does `h2` incorporate all of `h1`?
before :: History e -> History e -> Bool
before h1 h2 = go (currentHash h1) h2 where
  go h1 (Zero h) = h == h1
  go h1 (One _ history h) = h == h1 || go h1 history
  go h1 (Merge left right h) = h == h1 || go h1 left || go h1 right
```

Operations on a `Branch`:

* `add` a `Name` and associated `Code` to a `Branch`.
* `rename name1 name2`, checks that `name2` is available, and if so does the rename.
* `update oldcode oldnameafter newcode newname`, check that `newname` is available, if so add it to `edited` map. `oldcode` will be referred to using some fully-qualified name. `oldnameafter` will be the name for `oldcode` after the update, just like for `deprecate`.
* `deprecate oldcode newname` marks `oldcode` for deprecation, with optional `newname`, also adds this to `edited` map.
* `empty` creates a `Branch 0 newGuid Map.empty Map.empty Map.empty`, satisfies `merge b empty ~= b` and `merge empty b ~= b`, where `~=` compares branches ignoring their `branchId`.
* `fork b == merge new-branch b`

```haskell
Branch.lookup : Name -> Branch -> Set Code
Branch.lookup n b = case Map.lookup n (namespace b) of
  Nothing -> mempty
  Just (Causal.get -> NameEdits adds removes) ->
    upgrade b <$> (adds `Set.difference` removes)
    where
    upgrade b code = error "todo"
      -- using `edited b`, apply any type preserving subsitutions to `code`
      -- that exist in `b`
```

A branch is said to _cover_ a `cb : Set Code` when it has been developed to the point that the remaining updates are type-preserving and can thus be applied automatically. More precisely, a Branch `c` covers a `cb : Set Code` when all dependents in `cb` of type-changing edits in `c` (including deprecations) also have an edit in `c`, and none of the edits are in a conflicted state. If we want to measure how much work remains for a Branch `c` to cover a `cb : Codebase`, we can count the transitive dependents of all _escaped dependents_ of type-changing edits in `c`. An _escaped dependent_ is in `cb` but not `c`. This number will decrease monotonically as the `Branch` is developed.

_Related:_ There are some useful computations we can do to suggest which dependents of the frontier to upgrade next, based on what will make maximal progress in decreasing the remaining work. The idea is that it's useful to focus first on the "trunk" of a refactoring, which lots of code depend on, rather than the branches and leaves. Programmers sometimes try to do something like this when refactoring, but it can be difficult to know what's what when the main feedback you get from the compiler is just a big list of compile errors.

We also typically want to encourage the user to work on updates by expanding outward from initial changes, such that the set of edits form a connected dependency graph. If the user "skips over" nodes in the graph, there's a chance they'll need to redo their work, and we should notify the user about this. It's not something we need to prevent but we want the user to be aware that it's happening.

Thought: we may want to prevent a merge of `source` into `target` unless `source` covers all the definitions in `target` (either in the `namespace` or in the values of the `edited` `Map`). The user could develop `source` until it covers `target`, then the two branches can be merged. Alternately, we could just allow the branches to exist in an inconsistent state and prompt the user to fix these inconsistencies.

The `namespace` portion of a `Branch` can be built up using whatever logic the programmer wishes, including picking arbitrary new names for definitions, though very often, the names output by a `Branch` will be the same as or based on the names assigned to old versions of definitions.

This is it for the model. The rest of this document focuses on how to expose this nice model for use by the Unison programmer.

## The developer experience

When writing code, a developer has full access to all code that's been written, just by using different imports.

    > branch scratch
    There's no branch named 'scratch' yet.
    Would you like me to create it and switch to it? y/n
    > y
    ✅ I've created and switched to branch 'scratch'.
       Note: `> branch` can be used to show the active branch.
    > branch
    'scratch' at version 0
    > watch foo.u
    Watching foo.u for definitions to add to 'scratch' branch...
    Noticed a change, parsing and typechecking...
    🛑 I've found errors in 'foo.u', here's what I know:
    ...
    ✅ I've parsed and typechecked definitions in foo.u: `wrangle`
       Would you like to add this to the codebase? y/n
    > y
    ✅ It's done, using 'Alice' as author, Acme, Inc. as copyright holder,
       license is BSD3 (your chosen defaults). Use `> help license` if you'd
       like guidance on how to change any of this.
    > branch
    'scratch' at version 1
    > branch series/24
    ✅ Switched to 'series/24' branch
    > alias scratch.wrangle Acme.Alice.utils.wrangle
    ✅ I've marked a new definition 'Acme.Alice.utils.wrangle' for publication
       in 'series/24' branch.

_Question:_ what if `Acme.Alice.utils.wrangle` already exists in the 'series/24' branch? Unison reports a conflict and forces the user to pick a unique name:

    > alias scratch.wrangle Acme.Alice.utils.wrangle
    🛑 I'm afraid there's already a definition in this branch called 'Acme.Alice.utils.wrangle'.
       You can either `> move Acme.Alice.utils.wrangle <new name>` or choose
       a different local name for `scratch.wrangle`.

Another possibility: the name already exists locally and is coincidentally bound to the exact same `Code`, in which case we get a warning:

    > alias scratch.wrangle Acme.Alice.utils.wrangle
    🔸 There was already a definition `Acme.Alice.utils.wrangle` which was
       exactly equivalent to `scratch.wrangle`.

_Question:_ what if `scratch.wrangle` also exists in this branch? If you're using `alias`, you are always referring to another branch as the first argument. You can't alias a definition in the current branch as that would mean that a `Code` in this branch no longer had a unique name. (Alternate answer: some special syntax to disambiguate referring to another branch, like `scratch:wrangle` or `scratch/wrangle`, though if we do that, we would need to disallow that separator in branch identifiers)

_Question:_ How does Alice test that her changes actually work? She probably needs to propagate them out as far as her tests, assuming that's possible. But we obviously don't want to be recompiling and regenerating binaries on every edit. _Answer:_ The namespace of a branch refers to the latest version of everything, propagated as far as possible. Anything else has the prefix `old`. We achieve this just by keep a `Map Reference Reference` of type-compatible replacements which we then use in various places (such as the runtime) to do on-the-fly rewriting.

_Question:_ What about "third-party" dependencies? How do those fit in here? _Answer:_ These are tracked with first-class imports.

Assuming that is successful:

    > delete branch scratch
    ✅ I've deleted the 'scratch' branch.
    > git commit push
    ✅ I've committed and pushed 'series/24' updates (listed below)
       to https://github.com/acme/acme
       ...

It's not generally necessary to create a new branch every time, you can also just add definitions directly to the current base branch.

The `> branch blah` command creates a new branch with no ancestors. You can also create branches whose ancestor is the current branch, which is useful for a refactoring that you eventually want to merge back into the current branch.

    > fork major-refactoring
    ✅ I've created and switched to new branch 'major-refactoring'.
       It's a child of branch 'series/24' version 29381.
    > watch foo.u
    ...
    ✅ Added definition 'Acme.transmogrify'
    > branch series/24
    ✅ Switched to 'series/24' branch
    > merge major-refactoring
    ✅ Updated 182 definitions, no conflicts
    > save release/24
    ✅ Saved 'series/24' as branch 'release/24'

Note that a `use release/24` in your Unison code can be used to access the namespace of a branch.

### Publishing

To publish something for use by others, users just share a URL that links to their GitHub repository. There's no separate step of creating some artifact like a jar and uploading that to some third-party package repository. That URL is something like `https://acme.github.io/unison/QjdBS8sdbWdj`, where the `QjdBS8sdbWdj` is a Base 58 encoding of a particular Unison hash. The GitHub repository format for Unison doubles as a GitHub pages site so anyone can explore the repository from that point, obtaining pretty-printed and hyperlinked source code, pretty HTML documentation, and so on.

To start using someone else's published code, you can do a `get`:

    > get https://acme.github.io/unison/QjdBS8sdbWdj
    About to fetch 'https://acme.github.io/unison/release/24'.
    choose a name for the namespace (suggest 'acme'): acme

    Fetching...

    ✅ Loaded 1089 definitions into acme/release/24
       Use `> docs acme/release/24`

The URL here can point to a single definition, in which case it along with its transitive dependencies are added to the local codebase. In this case, it doesn't get a name, but you can refer to it by hash. Nameless code in the codebase probably records the URL where it was loaded from since that URL might have useful information about the hash. We might also by default look for `<url>/docs-**.link` or something to fetch documentation.

Alternately, we can juse `use` a release URL directly, as a namespace, without a `> get` happening first. Perhaps `use <any import expression> from <long url>`.  `<long url>` includes the hash of the release, which is a Unison Term including the namespace itself and references to a bunch of code. This is downloaded, along with all of its transitive dependencies. The namespace is spliced into the current parsing environment according to the import expression of the `use` statement.

Question: How do you discover new versions of hashes? (including hashes that refer to docs)

__Note:__ In the event of naming conflicts when doing a `get` (if you already have a branch with that name locally), Unison will force you to pick a different name.

## Repository format

TODO, update

A design goal of the repository format is that it can be versioned using Git (or Hg, or whatever), and there should never be merge conflicts when merging two Unison repositories. That is, Git merge conflicts are a bad UX for surfacing concurrent edits that the user may wish to reconcile.

Repository representation for this:

```good one
terms/
  jAjGDJnsdfL/
    compiled.ub  -- compiled form of the term
    type.ub    -- binary representation of the type of the term
    index.html -- pretty, hyperlinked source code of the term
    reference-english-JasVXOEBBV8.link -- link to docs, in English
    reference-spanish-9JasdfjHNBdjj.link -- link to docs, in Spanish
    doc-english-OD03VvvsjK.link -- other docs
    license-8JSJdkVvvow92.link -- reference to the license for this term
    author-38281234jf.link -- link to the hash of the authors list
types/ -- directory of all type declarations
  8sdfA1baBw/
    compiled.ub -- compiled form of the type declaration
    index.html  -- pretty, hyperlinked source code of the type decl
    reference-english-KgLfAIBw312.link -- reference docs
    doc-english-8AfjKBCXdkw.link -- other docs
    license-8JSJdkVvvow92.link -- reference to the license for this term
    author-38281234jf.link -- link to
    constructors/
      0/type.ub -- the type of the first ctor
      1/type.ub -- the type of the second ctor
branches/
  branchGuid7/
    myAwesomeBranch.name
    asdf8j23jd.ubf -- unison branch file, named according to its hash (so no conflicts), deserializes to a `Branch`
releases/
  releaseName1/
    asdf8j23jd.ur -- unison release file, named according to its hash, deserializes to a `Release`
```

Sets are represented by directories of immutable empty files whose file names represent the elements of the set - the sets are union'd as a result of a Git merge. Deletions are handled without conflicts as well.

Likewise, maps are represented by directories with a subdirectory named by each key in the map. The content of each subdirectory represents the value for that key in the map.

When doing a `git pull` or `git merge`, this can sometimes result in multiple `.ubf` files under a branch. We simply deserialize both `Branch` values, `merge` them, and serialize the result back to a file. The previous `.ubf` files can be deleted.

Observation: we'll probably want some additional indexing structure (which won't be versioned) which can be cached on disk and derived from the primary repo format. This is useful for answering different queries on the codebase more efficiently.

## Notes and ideas

You can have first-class imports with a type like:

```haskell
type Namespace = Map Name (Set Code) -> Map Code [NameEdit]
```

There's a nice little combinator library you can write to build up `Namespace` values in various ways, and we can imagine the Unison `use` syntax to be sugar for this library.

**Arya**: I'm still thinking we'll want something like scopes to be able to apply a branch to a prefix in a "clone package foo.x to foo.y and apply these changes" sort of wway.

package org.unisonweb

import org.unisonweb.util.PrettyPrint
import org.unisonweb.EasyTest._
import org.unisonweb.ABT.Name._

object DecompileTests {
  val tests = suite("decompile") (
    test("ex1") { implicit T =>
      val pingpong =
        Term.LetRec(
          "ping" -> Term.Lam("x")(Term.Var("pong")(Term.Var("x"))),
          "pong" -> Term.Lam("x")(Term.Num(79))) {
            Term.Var("ping")
          }
      note(PrettyPrint.prettyTerm(compilation.normalize(_ => ???)(pingpong)).render(40), includeAlways = true)
      ok
    },
    test("ex2") { implicit T =>
      val pingpong =
        Term.LetRec(
          "ping" -> Term.Lam("x")(Term.Var("pong")(Term.Var("x"))),
          "pong" -> Term.Lam("x")(Term.Var("ping")(Term.Var("x")))) {
            Term.Var("ping")
          }
      note(PrettyPrint.prettyTerm(compilation.normalize(_ => ???)(pingpong)).render(40), includeAlways = true)
      ok
    },
    test("ex3") { implicit T =>
      val pingpong =
        Term.LetRec(
          "foo" -> Term.Lam("x")(Term.Var("pang")(Term.Var("x"))),
          "pang" -> Term.Lam("x")(Term.Var("ping")(Term.Var("x"))),
          "ping" -> Term.Lam("x")(Term.Var("pong")(Term.Var("x"))),
          "pong" -> Term.Lam("x")(Term.Var("ping")(Term.Var("pang")(Term.Var("x"))))) {
            Term.Var("ping")
          }
      note(pingpong, true)
      note(PrettyPrint.prettyTerm(compilation.normalize(_ => ???)(pingpong)).render(40), includeAlways = true)
      ok
    }
  )

  // seems like there's something wonky with Refs appearing as the result of a computation
  // perhaps use types to prevent this from happening, types distinguish between things that can be passed a param (could be a ref)
  // vs things that may be returned from a computation (cannot be a ref)
  // seems like fullyDecompile not expanding Refs sufficiently?
}

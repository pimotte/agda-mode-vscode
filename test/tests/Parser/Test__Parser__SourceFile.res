open Belt
open BsMocha.Mocha
open Js.Promise
open Test__Util

describe("when parsing file paths", () =>
  it("should recognize the file extensions", () => {
    open SourceFile.FileType
    Assert.equal(parse("a.agda"), Agda)
    Assert.equal(parse("a.lagda"), LiterateTeX)
    Assert.equal(parse("a.lagda.tex"), LiterateTeX)
    Assert.equal(parse("a.lagda.md"), LiterateMarkdown)
    Assert.equal(parse("a.lagda.rst"), LiterateRST)
    Assert.equal(parse("a.lagda.org"), LiterateOrg)
  })
)

if onUnix {
  describe("when parsing source files (Unix only)", () => {
    describe("Regex.comment", () => {
      it("should work", () => {
        open SourceFile
        let match = Js.String.search(Regex.comment)
        Assert.equal(match("no comment"), -1)
        Assert.equal(match("no comment\n"), -1)
        Assert.equal(match("-- comment"), 0)
        Assert.equal(match("-- comment with newline\n"), 0)
      })

      it("should work when \"--\" is placed immediately after some text (issue #56)", () => {
        open SourceFile
        let match = Js.String.search(Regex.comment)
        Assert.equal(match("a -- comment after some text"), 2)
        Assert.equal(match("a-- comment placed immediately after some text"), -1)
        Assert.equal(match("_-- comment placed immediately after name parts"), 1)
        Assert.equal(match(";-- comment placed immediately after name parts"), 1)
        Assert.equal(match(".-- comment placed immediately after name parts"), 1)
        Assert.equal(match("\"-- comment placed immediately after name parts"), 1)
        Assert.equal(match("(-- comment placed immediately after name parts"), 1)
        Assert.equal(match(")-- comment placed immediately after name parts"), 1)
        Assert.equal(match("{-- comment placed immediately after name parts"), 1)
        Assert.equal(match("}-- comment placed immediately after name parts"), 1)
        Assert.equal(match("@-- comment placed immediately after name parts"), 1)
      })
    })

    Golden.getGoldenFilepathsSync(
      "../../../../test/tests/Parser/SourceFile",
    )->Array.forEach(filepath =>
      BsMocha.Promise.it("should golden test " ++ filepath, () =>
        Golden.readFile(filepath) |> then_(raw =>
          raw
          ->Golden.map(SourceFile.parse([0, 1, 2, 3, 4, 5, 6, 7, 8, 9], filepath))
          ->Golden.map(Strings.serializeWith(SourceFile.Diff.toString))
          ->Golden.compare
        )
      )
    )
  })
}

package tests.operations;

import buddy.*;
using buddy.Should;

class ParseQuery extends BuddySuite
{
  // TODO: directives:  content @include(if: $include_content) {

  public static inline var basic_query = '
{
  title
  id
  course_id
  content {
    id
  }
  unlock_at
  submissions {
    id
  }
}
';

  public static inline var args_query = '
query GetReturnOfTheJedi($$id: ID) {
  film(id: $$id) {
    title
    director
    releaseDate
  }
}';

  public function new() {
    describe("ParseQuery: The Parser", {

      var parser:graphql.parser.Parser;

      it('should parse the BASIC query document without error', {
        parser = new graphql.parser.Parser(basic_query);
      });

      it("should parse 1 definitions and 6 selections from this schema", {
        parser.document.definitions.length.should.be(1);

        parser.document.definitions[0].selectionSet.selections.length.should.be(6);
      });


      it('should parse the ARGS query document without error', {
        parser = new graphql.parser.Parser(args_query);
      });

      it("should parse 1 definitions and 6 selections from this schema", {
        parser.document.definitions.length.should.be(1);

        parser.document.definitions[0].selectionSet.selections.length.should.be(1);
      });

    });
  }

}

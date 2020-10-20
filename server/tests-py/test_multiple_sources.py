from validate import check_query
import pytest

usefixtures = pytest.mark.usefixtures

@usefixtures('per_class_tests_sources')
# @usefixtures('per_class_tests_db_state')
class TestAddSource():
    def test_add_source(self, hge_ctx):
        add_source_query = {
            'url': "/v1/metadata",
            'status': 200,
            'response': {'message': 'success'},
            'query': {
                    'type': 'pg_add_source',
                    'args': {
                        'name': 'src2',
                        'database_url': hge_ctx.pg_url
                    }
                }
            }
        check_query(hge_ctx, add_source_query)

    @classmethod
    def dir(cls):
        return "queries/sources"



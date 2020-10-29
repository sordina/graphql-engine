FROM python:3

RUN mkdir -p /graphql-engine/server/

COPY . /graphql-engine/server/tests-py
COPY get-version.sh /graphql-engine/scripts/get-version.sh

WORKDIR /graphql-engine/server/tests-py

RUN pip install -r requirements.txt

CMD [ "pytest", "--hge-urls", "http://localhost:8080", "--pg-urls=postgres://postgres@localhost:5432/hasura-test-metadata-1", "test_multiple_sources.py", "-vvv" ]

# CMD [ "pytest", "./your-daemon-or-script.py" ]

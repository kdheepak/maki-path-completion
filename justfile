set dotenv-load := true
set positional-arguments := true
set default-list := true

# Run the path completion tests
test *args:
    @mise run test -- "$@"

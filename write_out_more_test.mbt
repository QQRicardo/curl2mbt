///|
test "the program for %{scheme}, %{urlnum}, %{filename_effective}, %{redirect_url} and %header{}" {
  let code = (text : String) => @curl2mbt.parse(text).plan.emit().code
  let program = code(
    "curl -w '[%{scheme}][%{urlnum}][%{filename_effective}][%{redirect_url}][%header{X-A}]' 'https://h/a?b'",
  )
  assert_true(
    program.contains(
      "  let redirect_url = redirect_url(response, \"https://h\", \"/a?b\")\n",
    ),
  )
  assert_true(
    program.contains(
      "  let header_1 = response.headers.get(\"X-A\").unwrap_or(\"\")\n",
    ),
  )
  assert_true(
    program.contains(
      "  @stdio.stdout.write(\"[https][0][][\\{redirect_url}][\\{header_1}]\")\n",
    ),
  )
  assert_true(program.contains("fn redirect_target("))
  // With -L curl has followed the redirect; the scheme is that of the end.
  let program = code("curl -L -w '[%{scheme}][%{redirect_url}]' http://h/")
  assert_true(
    program.contains(
      "      transfer.scheme = if origin.has_prefix(\"https:\") { \"https\" } else { \"http\" }\n",
    ),
  )
  assert_true(
    program.contains("  @stdio.stdout.write(\"[\\{transfer.scheme}][]\")\n"),
  )
  assert_false(program.contains("fn redirect_url("))
  // The name of the file that --no-clobber writes.
  let program = code(
    "curl --no-clobber -o out -w '%{filename_effective}' http://h/",
  )
  assert_true(
    program.contains("  let written = write_new_file(\"out\", body)\n"),
  )
  assert_true(program.contains("  @stdio.stdout.write(\"\\{written}\")\n"))
  let program = code("curl -o d/out -w '%{filename_effective}' http://h/")
  assert_true(program.contains("  @stdio.stdout.write(\"d/out\")\n"))
}

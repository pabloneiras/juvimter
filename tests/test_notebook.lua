-- Headless Neovim unit test suite for juvimter.nvim
-- Run via: nvim --headless -u NONE --cmd "set rtp+=." -l tests/test_notebook.lua

local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    error(string.format("ASSERTION FAILED (%s):\n  expected: %s\n  actual:   %s", msg or "", vim.inspect(expected), vim.inspect(actual)))
  end
end

local function assert_true(cond, msg)
  if not cond then
    error("ASSERTION FAILED: " .. (msg or "expected true"))
  end
end

print("=== Running juvimter.nvim Lua unit tests ===")

-- 1. Setup & config
local juvimter = require("juvimter")
juvimter.setup({ auto_attach = true })

-- 2. Notebook parse & serialize round-trip
local notebook = require("juvimter.notebook")
local demo_raw = table.concat(vim.fn.readfile("examples/demo.ipynb"), "\n")
local nb, err = notebook.parse(demo_raw)
assert_true(err == nil, "parse demo.ipynb without error")
assert_eq(#nb.cells, 6, "demo.ipynb cell count")
assert_eq(nb.cells[1].cell_type, "markdown", "cell 1 is markdown")
assert_eq(nb.cells[2].cell_type, "code", "cell 2 is code")
assert_eq(nb.cells[2].id, "b2c3d4e5", "cell 2 ID preserved")

-- Add synthetic outputs and verify round-trip serialization
nb.cells[2].execution_count = 1
nb.cells[2].outputs = {
  { output_type = "stream", name = "stdout", text = "hello world\nline 2\n" },
  {
    output_type = "execute_result",
    execution_count = 1,
    data = { ["text/plain"] = "42" },
    metadata = {},
  },
}

local serialized = notebook.serialize(nb)
local nb2, err2 = notebook.parse(serialized)
assert_true(err2 == nil, "re-parse serialized notebook")
assert_eq(#nb2.cells, 6, "round-trip cell count")
assert_eq(nb2.cells[2].execution_count, 1, "round-trip execution_count")
assert_eq(#nb2.cells[2].outputs, 2, "round-trip output count")
assert_eq(nb2.cells[2].outputs[2].data["text/plain"], "42", "round-trip execute_result")
assert_eq(nb2.nbformat, 4, "nbformat == 4")
assert_eq(nb2.nbformat_minor, 5, "nbformat_minor == 5")
print("  [PASS] notebook.lua nbformat 4.5 round-trip")

-- 3. ANSI parser
local ansi = require("juvimter.ansi")
local chunks = ansi.parse_line("\27[31;1mValueError\27[0m: bad value")
assert_true(#chunks >= 2, "ANSI parsed into chunks")
assert_eq(chunks[1][1], "ValueError", "ANSI chunk 1 text")
assert_eq(chunks[2][1], ": bad value", "ANSI chunk 2 text")
assert_eq(ansi.strip("\27[32mOK\27[0m"), "OK", "ANSI strip")
print("  [PASS] ansi.lua parser & stripper")

-- 4. HTML table renderer (pandas DataFrame)
local html_table = require("juvimter.html_table")
local sample_html = [[
<div>
<table border="1" class="dataframe">
  <thead>
    <tr><th></th><th>model</th><th>acc</th></tr>
  </thead>
  <tbody>
    <tr><th>0</th><td>ResNet</td><td>76.1</td></tr>
    <tr><th>1</th><td>ViT</td><td>81.8</td></tr>
  </tbody>
</table>
<p>2 rows × 2 columns</p>
</div>
]]
local tlines = html_table.render(sample_html)
assert_true(tlines ~= nil and #tlines >= 5, "HTML table rendered lines")
print("  [PASS] html_table.lua DataFrame renderer")

-- 5. Pure-Lua PNG dimension parser
local images = require("juvimter.images")
-- Minimal 16x32 PNG header bytes
local png_hdr = "\137PNG\r\n\26\n\0\0\0\13IHDR\0\0\0\16\0\0\0\32\8\2\0\0\0"
local pw, ph = images.parse_dimensions(png_hdr, "image/png")
assert_eq(pw, 16, "PNG width")
assert_eq(ph, 32, "PNG height")
print("  [PASS] images.lua pure-Lua PNG header parser")

-- 6. Buffer open, cell operations (insert, move, toggle, split, merge) & write
local buffer = require("juvimter.buffer")
local tmp_path = vim.fn.tempname() .. ".ipynb"
vim.fn.writefile(vim.split(serialized, "\n", { plain = true }), tmp_path)

local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_buf_set_name(buf, tmp_path)
buffer.open_ipynb(buf, tmp_path)

local doc = buffer.sync_from_buffer(buf)
assert_eq(#doc.nb.cells, 6, "buffer loaded 6 cells")
assert_eq(vim.bo[buf].filetype, "python", "filetype auto-detected as python")
assert_eq(doc.nb.cells[2].execution_count, 1, "cell 2 execution_count preserved in buffer")

-- Insert code cell below cell 1
buffer.focus_cell(buf, 1)
buffer.insert_cell_below(buf, "code")
doc = buffer.sync_from_buffer(buf)
assert_eq(#doc.nb.cells, 7, "insert_cell_below increased cell count to 7")

-- Toggle new cell to markdown and back
buffer.toggle_cell_type(buf)
doc = buffer.sync_from_buffer(buf)
assert_eq(doc.nb.cells[2].cell_type, "markdown", "toggle_cell_type -> markdown")

buffer.toggle_cell_type(buf)
doc = buffer.sync_from_buffer(buf)
assert_eq(doc.nb.cells[2].cell_type, "code", "toggle_cell_type -> code")

-- Delete the inserted cell
buffer.delete_cell(buf)
doc = buffer.sync_from_buffer(buf)
assert_eq(#doc.nb.cells, 6, "delete_cell restored cell count to 6")

-- Save back to disk and verify valid JSON
local out_path = vim.fn.tempname() .. ".ipynb"
buffer.write_ipynb(buf, out_path)
local saved_raw = table.concat(vim.fn.readfile(out_path), "\n")
local saved_nb, serr = notebook.parse(saved_raw)
assert_true(serr == nil, "saved .ipynb is valid JSON")
assert_eq(#saved_nb.cells, 6, "saved .ipynb has 6 cells")
assert_eq(saved_nb.cells[2].execution_count, 1, "saved .ipynb preserved execution_count")
assert_eq(#saved_nb.cells[2].outputs, 2, "saved .ipynb preserved outputs")

vim.fn.delete(tmp_path)
vim.fn.delete(out_path)
print("  [PASS] buffer.lua open/edit/cell-ops/write_ipynb")
print("=== ALL LUA TESTS PASSED! ===")

# Fix #8: os.system() injection risk in dependent-rake.yml

## Problem
The Python inline script in `dependent-rake.yml:107-137` uses:
```python
gem_name = '${{ github.event.repository.name }}'
os.system("bundle add {} --path ..".format(gem_name))
```
`os.system()` with string formatting is a shell injection vector if repo name contains metacharacters.

## Fix
Use `subprocess.run()` with argument list:
```python
subprocess.run(["bundle", "add", gem_name, "--path", ".."], check=True)
```

## Status
- [x] Done

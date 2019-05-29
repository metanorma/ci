# Ci::Master

Main propose of this gem to manage CI configuration accross all repos in [metanorma organization](https://github.com/metanorma)

## Installation

Highly likelly this gem will not be published, because it's only for internal usage

### Prerequisites

- `pip install git-plus`
- `brew install hub`

## Usage

### Checkout all repos

- `mkdir mn-root`
- `cd mn-root`
- `repo init -u https://github.com/metanorma/metanorma-build-scripts`
- `repo sync`

### Make sure repos up-to-date

- `git -C ../../ multi checkout master`
- `git -C ../../ multi pull`

### Propogate changes from ci-master

- `cd metanorma-build-scripts/ci-master`
- `bin/ci-master sync -r ../../ -c config`
- `git multi -c checkout -b feature/xxx`
- `git multi -c add -u .travis.yml`
- `git multi -c add -u appveyor.yml`
- `git multi commit -m "Update CI configuration due to XXX feature"`
- `git multi push --set-upstream github feature/xxx`
- `for f in */; do if [ -d "$f/.git" ]; then cd $f; hub pull-request -b master -r ronaldtse -a CAMOBAP795 --no-edit; cd ..; fi; done`

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/metanorma/metanorma-build-scripts. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [Contributor Covenant](http://contributor-covenant.org) code of conduct.

## Code of Conduct

Everyone interacting in the Ci::Master project’s codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/metanorma/metanorma-build-scripts/blob/master/ci-master/CODE_OF_CONDUCT.md).

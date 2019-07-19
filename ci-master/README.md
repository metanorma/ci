# Ci::Master

Main propose of this gem to manage CI configuration accross all repos in [metanorma organization](https://github.com/metanorma)

## Installation

Highly likelly this gem will not be published, because it's only for internal usage

### Prerequisites

- [`repo`](https://source.android.com/setup/build/downloading#installing-repo)
- `pip install git-plus`
- `brew install hub`

## Usage

### Checkout all repos

- `mkdir mn-root`
- `cd mn-root`
- `repo init -u https://github.com/metanorma/metanorma-build-scripts`
- `repo sync`
- `echo 'metanorma-build-scripts' > .multigit_ignore`
- `cd metanorma-build-scripts/ci-master`

### Make sure repos up-to-date

- `bin/ci-master pull -b master -r ../..`

### Propogate changes from ci-master

- `bin/ci-master pull -r ../.. -b feature/xxx [-m "Update CI configuration due to XXX feature" | -f]`
- `bin/ci-master open-prs -r ../.. -e ronaldtse -a CAMOBAP795`

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/metanorma/metanorma-build-scripts. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [Contributor Covenant](http://contributor-covenant.org) code of conduct.

## Code of Conduct

Everyone interacting in the Ci::Master project’s codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/metanorma/metanorma-build-scripts/blob/master/ci-master/CODE_OF_CONDUCT.md).

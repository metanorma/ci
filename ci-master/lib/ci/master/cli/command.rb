require 'json'
require 'yaml'
require 'net/http'

require 'travis/client/session'

require 'rexml/document'
include REXML

module Ci
  module Master
    module Cli
      class Command
        def sync(options)
          config_path = validate_config_path(options)
          repos_path, repo_manifest_path = validate_repo_path(options)

          config = YAML.load_file(File.join(config_path, 'ci.yml'))

          manifest = Document.new(File.new(repo_manifest_path))

          config['repos'].each do |repo_name, repo_ci|
            repo_path = File.join(repos_path, repo_name)

            next unless File.exist?(repo_path)
            next unless repo_in_group(manifest, repo_name, options[:groups])

            travisci, appveyor = repo_ci.values_at('.travis.yml', 'appveyor.yml')

            if travisci then
              copy_file File.join(config_path, travisci), File.join(repo_path, '.travis.yml'), options[:dry_run]
            end

            if appveyor then
              copy_file File.join(config_path, appveyor), File.join(repo_path, 'appveyor.yml'), options[:dry_run]
            end
          end
        end

        def lint(options)
          config_path = validate_config_path(options)
          appveyor_token = options[:appveyor_token]

          config = YAML.load_file(File.join(config_path, 'ci.yml'))

          validated = []

          config['repos'].each do |_, repo_ci|
            travisci, appveyor = repo_ci.values_at('.travis.yml', 'appveyor.yml')

            if travisci && !validated.include?(travisci) then
              valid = system("travis lint #{File.join(config_path, travisci)}", :out => :close)
              puts "#{travisci} valid: #{valid}"
              validated << travisci
            end

            if appveyor && !validated.include?(appveyor)  then
              uri = URI('https://ci.appveyor.com/api/projects/validate-yaml')
              http = Net::HTTP.new(uri.host, uri.port)
              http.use_ssl = true

              req = Net::HTTP::Post.new(uri.path, {
                "Content-Type" => "application/json",
                "Authorization" => "Bearer #{appveyor_token}"
              })
              req.body = File.read(File.join(config_path, appveyor))

              valid = http.request(req).kind_of? Net::HTTPSuccess

              puts "#{appveyor} valid: #{valid}"
              validated << appveyor
            end
          end
        end

        def pull(options)
          repos_path, repo_manifest_path = validate_repo_path(options)
          config_path = validate_config_path(options)
          pull_branch = options[:pull_branch]

          config = YAML.load_file(File.join(config_path, 'ci.yml'))
          manifest = Document.new(File.new(repo_manifest_path))

          config['repos'].each do |repo_name, repo_ci|
            repo_path = File.join(repos_path, repo_name)

            next unless File.exist?(repo_path)
            next unless repo_in_group(manifest, repo_name, options[:groups])

            puts "Pull #{repo_path} ..."
            Dir.chdir(repo_path) {
              system("git checkout #{pull_branch} && git pull")
            }
          end

          puts "Done!"
        end

        def push(options)
          repos_path, = validate_repo_path(options)
          push_branch = options[:push_branch]
          commit_message = options[:commit_message]
          force_push = options[:force_push]
          dry_run = options[:dry_run]

          unless force_push
            raise OptionParser::MissingArgument, "Missing -m/--message value" if commit_message.nil?
            raise OptionParser::MissingArgument, "Missing -b/--push-branch value" if push_branch.nil?

            run_cmd("git -C #{repos_path} multi -c checkout -b #{push_branch}")
          end
          
          # do two separate `git add` because one of it may be missing
          run_cmd("git -C #{repos_path} multi -c add .travis.yml", dry_run)
          run_cmd("git -C #{repos_path} multi -c add appveyor.yml")

          if force_push
            run_cmd("git -C #{repos_path} multi commit --amend --no-edit")
            run_cmd("git -C #{repos_path} multi -c push -f")
          else
            run_cmd("git -C #{repos_path} multi commit -m '#{commit_message}'")
            run_cmd("git -C #{repos_path} multi push --set-upstream github #{push_branch}")
          end
        end

        def open_prs(options)
          repos_path, = validate_repo_path(options)
          authors = options[:authors]
          reviewers = options[:reviewers]

          Pathname.new(repos_path).children.each do |path|
            if path.directory? && (path + '.git').directory? && path.basename != 'metanorma-build-scripts'
              Dir.chdir(path) {
                run_cmd("hub pull-request -b master -r #{reviewers} -a #{authors} --no-edit", options[:dry_run]) 
              }
            end
          end
        end

        private

        def copy_file(from, to, dry_run)
          puts "Copy #{from} to #{to}"
          if !dry_run then
            File.open(to, 'w') do |fo|
              fo.puts '# Auto-generated !!! Do not edit it manually'
              fo.puts '# use ci-master https://github.com/metanorma/metanorma-build-scripts'
              File.foreach(from) do |li|
                fo.puts li
              end
            end
          end
        end

        def run_cmd(cmd, dry_run)
          if dry_run
            puts "dry run: cwd:#{Dir.pwd} system(#{cmd})" 
          else
            system(cmd)
          end
        end

        def validate_repo_path(options)
          repos_path = options[:repo_dir_path]
          repo_manifest_path = repos_path + '.repo/manifest.xml'

          raise OptionParser::MissingArgument, "Missing -r/--repo-path value" if repos_path.nil? || !repos_path.exist?
          raise OptionParser::MissingArgument, "Wrong -r/--repo-path value, no manifest #{repo_manifest_path} found" if !repo_manifest_path.exist?
          
          return repos_path, repo_manifest_path
        end

        def validate_config_path(options)
          config_path = options[:config_dir_path]
          
          raise OptionParser::MissingArgument, "Missing -c/--config-path value" if config_path.nil? || !config_path.exist?

          return config_path
        end

        def repo_in_group(manifest_doc, repo_name, groups)
          groups_xpath = %(/manifest/project[@name="metanorma/#{repo_name}"]/@groups)

          repo_groups_attr = XPath.first(manifest_doc, groups_xpath)
          unless repo_groups_attr
            return false
          end
          repo_groups = repo_groups_attr.value.split(',')

          !(groups & repo_groups).empty?
        end
      end
    end
  end
end

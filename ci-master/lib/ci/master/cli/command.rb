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
					config_path = options[:config_dir_path]
					repos_path = options[:repo_dir_path]
					groups = options[:groups]
					repo_manifest_path = repos_path + '.repo/manifest.xml'

					raise OptionParser::MissingArgument, "Missing -r/--repo-path value" if repos_path.nil? || !repos_path.exist?
					raise OptionParser::MissingArgument, "Wrong -c/--config-path value, no manifest #{repo_manifest_path} found" if !repo_manifest_path.exist?
					raise OptionParser::MissingArgument, "Missing -c/--config-path value" if config_path.nil? || !config_path.exist?

					config = YAML.load_file(File.join(config_path, 'ci.yml'))

					manifest = Document.new(File.new(repo_manifest_path))

					config['repos'].each do |repo_name, repo_ci|
					  repo_path = File.join(repos_path, repo_name)
					  groups_xpath = %(/manifest/project[@name="metanorma/#{repo_name}"]/@groups)
					  repo_groups = XPath.first(manifest, groups_xpath).value.split(',')

					  next unless File.exist?(repo_path) && !(groups & repo_groups).empty?
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
					config_path = options[:config_dir_path]
					appveyor_token = options[:appveyor_token]

					raise OptionParser::MissingArgument, "Missing -c/--config-path value" if config_path.nil? || !config_path.exist?

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
	    end
    end
  end
end

require 'rake/clean'
require 'configatron'
Dir.glob(File.join(File.dirname(__FILE__), 'tools/Rake/*.rb')).each do |f|
	require f
end

task :default => [:clobber, 'compile:all', 'tests:run', :package]

desc 'Runs a quick build just compiling the libs that are not up to date'
task :quick do
	CLOBBER.clear
	
	class MSBuild
		class << self
			alias do_compile compile
		end

		def self.compile(attributes)
			artifacts = artifacts_of attributes[:project]
			do_compile attributes unless uptodate? artifacts, FileList.new("#{attributes[:project].dirname}/**/*.*")
		end
		
		def self.artifacts_of(project)
			FileList.new() \
				.include("#{configatron.dir.build}/**/#{project.dirname.name}.dll") \
				.include("#{configatron.dir.build}/**/#{project.dirname.name}.exe")
		end
		
		def self.uptodate?(new_list, old_list)
			return false if new_list.empty?
			
			new_list.each do |new|
				return false unless FileUtils.uptodate? new, old_list
			end
			
			return true
		end
	end
end

namespace :env do
	desc 'Switches the configuration to the development environment'
	task :development do
		configure_env_for 'development'
	end
	
	desc 'Switches the configuration to the test environment'
	task :test do
		configure_env_for 'test'
	end

	desc 'Switches the configuration to the production environment'
	task :production do
		configure_env_for 'production'
	end
	
	def configure_env_for(env_key)
		env_key = env_key || 'development'

		puts "Loading settings for the '#{env_key}' environment"
		yaml = Configuration.load_yaml 'properties.yml', :hash => env_key, :inherit => :default_to, :override_with => :local_properties
		configatron.configure_from_hash yaml
		
		configatron.build.number = ENV['BUILD_NUMBER']
		configatron.database.connectionstring = "Data Source=#{configatron.database.server}; Initial Catalog=#{configatron.database.name}; #{'Integrated Security=true; ' if configatron.database.sspi} Persist Security Info=False;"
		configatron.deployment.package = "#{configatron.project}-#{configatron.build.number || '1.0.0.0'}.zip".in(configatron.dir.deploy)

		CLEAN.clear
		CLEAN.include('teamcity-info.xml')
		CLEAN.include('**/obj'.in(configatron.dir.source))
		CLEAN.include('**/*'.in(configatron.dir.test_results))
				
		CLOBBER.clear
		CLOBBER.include(configatron.dir.build)
		CLOBBER.include(configatron.dir.deploy)
		CLOBBER.include('**/bin'.in(configatron.dir.source))
		CLOBBER.include('**/*.template'.in(configatron.dir.source))
		# Clean template results.
		CLOBBER.map! do |f|
			next f.ext() if f.pathmap('%x') == '.template'
			f
		end
		
		configatron.protect_all!

		puts configatron.inspect
	end

	# Load the default environment configuration if no environment is passed on the command line.
	Rake::Task['env:development'].invoke \
		if not Rake.application.options.show_tasks and
		   not Rake.application.options.show_prereqs and
		   not Rake.application.top_level_tasks.any? do |t|
			/^env:/.match(t)
		end
end
	
namespace :generate do
	desc 'Updates the version information for the build'
	task :version do
		next if configatron.build.number.nil?
		
		asmInfo = AssemblyInfoBuilder.new({
				:AssemblyFileVersion => configatron.build.number,
				:AssemblyVersion => configatron.build.number
			})
			
		asmInfo.write 'VersionInfo.cs'.in(configatron.dir.source)
	end

	desc 'Updates the configuration files for the build'
	task :config do
		FileList.new("#{configatron.dir.source}/**/*.template").each do |template|
			QuickTemplate.new(template).exec(configatron)
		end
	end
end

namespace :db do
	desc 'Creates the database'
	task :create do
		invoke_tarantino :create
	end
	
	desc 'Updates the database'
	task :update do
		invoke_tarantino :update
	end
	
	desc 'Drops the database'
	task :drop do
		invoke_tarantino :drop
	end
	
	desc 'Rebuilds the database'
	task :rebuild do
		invoke_tarantino :rebuild
	end
	
	def invoke_tarantino(action, script = configatron.database.scripts)
		Tarantino.run \
			:action => action,
			:tool => configatron.tools.tarantino,
			:script_dir => script,
			:server => configatron.database.server,
			:database => configatron.database.name,
			:sspi => configatron.database.sspi,
			:username => configatron.database.username,
			:password => configatron.database.password
	end
	
	namespace :export do
		desc 'Exports the create scripts'
		task :create => 'compile:dbtools' do
			outFile = '0001_Create schema.sql'.in(configatron.dir.deploy).to_absolute
			Dir.chdir("#{configatron.dir.build}/DbTool") do
				puts "Exporting the schema creation script to #{outFile}"
				sh "#{"#{configatron.project}.Tools.Database.exe".escape} /Operation:ExportCreate /OutputFile:#{outFile.escape}"
			end
		end
		
		desc 'Exports the update script (forward migration)'
		task :update  => 'compile:dbtools' do
			outFile = 'Update.sql'.in(configatron.dir.deploy).to_absolute
			Dir.chdir("#{configatron.dir.build}/DbTool") do
				puts "Exporting the schema update script to #{outFile}"
				sh "#{"#{configatron.project}.Tools.Database.exe".escape} /Operation:ExportUpdate /OutputFile:#{outFile.escape}"
			end
		end
		
		desc 'Exports the data in the current database'
		task :sample_data do
			SqlPubWiz.run\
				:tool => configatron.tools.sqlpubwiz,
				:connection_string => configatron.database.connectionstring,
				:output_file => 'Sample data.sql'.in(configatron.database.sample_data)
		end
	end
	
	namespace :import do
		desc 'Imports sample data'
		task :sample_data => 'db:rebuild' do
			invoke_tarantino :execute_script, 'Sample data.sql'.in(configatron.database.sample_data)
		end
	end
end

namespace :compile do
	desc 'Compiles the application'
	task :app => [:clobber, 'generate:version', 'generate:config'] do
		FileList.new("#{configatron.dir.app}/**/*.Application.csproj", "#{configatron.dir.app}/**/*.Modules.*.csproj").each do |project|
			MSBuild.compile \
				:project => project,
				:properties => {
					:SolutionDir => configatron.dir.source.to_absolute.chomp('/').concat('/').escape,
					:Configuration => configatron.build.configuration,
					:TreatWarningsAsErrors => true
				}
		end
	end

	desc 'Compiles the tests'
	task :tests => [:clobber, 'generate:version', 'generate:config'] do
		FileList.new("#{configatron.dir.test}/**/*.csproj").each do |project|
			MSBuild.compile \
				:project => project,
				:properties => {
					:SolutionDir => configatron.dir.source.to_absolute.chomp('/').concat('/').escape,
					:Configuration => configatron.build.configuration
				}
		end
	end
	
	desc 'Compiles the database tools'
	task :dbtools => [:clobber, 'generate:version', 'generate:config'] do
		FileList.new("#{configatron.dir.app}/#{configatron.project}.Tools.Database/#{configatron.project}.Tools.Database.csproj").each do |project|
			MSBuild.compile \
				:project => project,
				:properties => {
					:SolutionDir => configatron.dir.source.to_absolute.chomp('/').concat('/').escape,
					:Configuration => configatron.build.configuration,
					:TreatWarningsAsErrors => true
				}
		end
	end
	
	task :all => [:app, :tests, :dbtools]
end

namespace :tests do
	desc 'Runs unit tests'
	task :run => ['compile:tests', 'db:rebuild'] do
		FileList.new("#{configatron.dir.build}/Test/**/*.Tests.dll").each do |assembly|
			Mspec.run \
				:tool => configatron.tools.mspec,
				:reportdirectory => configatron.dir.test_results,
				:assembly => assembly
		end
	end
	
	desc 'Runs CLOC to create some source code statistics'
	task :cloc do
		results = Cloc.count_loc \
			:tool => configatron.tools.cloc,
			:report_file => 'cloc.xml'.in(configatron.dir.test_results),
			:search_dir => configatron.dir.source,
			:statistics => {
				:'LOC.CS' => '/results/languages/language[@name=\'C#\']/@code',
				:'Files.CS' => '/results/languages/language[@name=\'C#\']/@files_count',
				:'LOC.Total' => '/results/languages/total/@code',
				:'Files.Total' => '/results/languages/total/@sum_files'
			} do |key, value|
				TeamCity.add_statistic key, value
			end
		
		TeamCity.append_build_status_text "#{results[:'LOC.CS']} LOC in #{results[:'Files.CS']} C# Files"
	end
	
	desc 'Runs NCover code coverage'
	task :ncover => ['compile:tests', 'db:rebuild'] do
		applicationAssemblies = FileList.new() \
			.include("#{configatron.dir.build}/Test/**/#{configatron.project}*.dll") \
			.include("#{configatron.dir.build}/Test/**/#{configatron.project}*.exe") \
			.exclude(/(Tests\.dll$)|(ForTesting\.dll$)/) \
			.exclude(/\.exe$/) \
			.pathmap('%n') \
			.join(';')
			
		FileList.new("#{configatron.dir.build}/Test/**/*.Tests.dll").each do |assembly|
			NCover.run_coverage \
				:tool => configatron.tools.ncover,
				:report_dir => configatron.dir.test_results,
				:working_dir => assembly.dirname,
				:application_assemblies => applicationAssemblies,
				:program => configatron.tools.mspec,
				:assembly => assembly.to_absolute.escape,
				:args => ["#{('--teamcity ' if ENV['TEAMCITY_PROJECT_NAME']) || ''}"]
		end
		
		NCover.explore \
			:tool => configatron.tools.ncoverexplorer,
			:project => configatron.project,
			:report_dir => configatron.dir.test_results,
			:html_report => 'Coverage.html',
			:xml_report => 'Coverage.xml',
			:min_coverage => 70,
			:fail_if_under_min_coverage => true,
			:statistics => {
				:NCoverCodeCoverage => "/coverageReport/project/@functionCoverage"
			} do |key, value|
				TeamCity.add_statistic key, value
				TeamCity.append_build_status_text "Code coverage: #{Float(value.to_s).round}%"
			end
	end
	
	desc 'Runs FxCop to analyze assemblies for compliance with the coding guidelines'
	task :fxcop => [:clean, 'compile:app'] do
		results = FxCop.analyze \
			:tool => configatron.tools.fxcop,
			:project => 'Settings.FxCop'.in(configatron.dir.source),
			:report => 'FxCop.html'.in(configatron.dir.test_results),
			:apply_report_xsl => true,
			:report_xsl => 'CustomFxCopReport.xsl'.in("#{configatron.tools.fxcop.dirname}/Xml"),
			:console_output => true,
			:console_xsl => 'FxCopRichConsoleOutput.xsl'.in("#{configatron.tools.fxcop.dirname}/Xml"),
			:show_summary => true,
			:fail_on_error => false,
			:assemblies => FileList.new() \
				.include("#{configatron.dir.build}/Application/**/#{configatron.project}*.dll") \
				.exclude('**/*.vshost') \
			do |violations|
				TeamCity.append_build_status_text "#{violations} FxCop violation(s)"
				TeamCity.add_statistic 'FxCopViolations', violations
			end	
	end
	
	desc 'Runs StyleCop to analyze C# source code for compliance with the coding guidelines'
	task :stylecop do
		results = StyleCop.analyze \
			:tool => configatron.tools.stylecop,
			:directories => configatron.dir.app,
			:ignore_file_pattern => ['(?:Version|Solution|Assembly|FxCop)Info\.cs$', '\.Designer\.cs$', '\.hbm\.cs$', 'QueryBuilder\.cs$'],
			:settings_file => 'Settings.StyleCop'.in(configatron.dir.source),
			:report => 'StyleCop.xml'.in(configatron.dir.test_results),
			:report_xsl => 'StyleCopReport.xsl'.in(configatron.tools.stylecop.dirname) \
			do |violations|
				TeamCity.append_build_status_text "#{violations} StyleCop violation(s)"
				TeamCity.add_statistic 'StyleCopViolations', violations
			end
	end
	
	desc 'Run all code quality-related tasks'
	task :quality => [:ncover, :cloc, :fxcop, :stylecop]
end

desc 'Packages the build artifacts'
task :package => 'compile:app' do
	sz = SevenZip.new({ :tool => configatron.tools.zip,
				:zip_name => configatron.deployment.package })
	
	Dir.chdir("#{configatron.dir.build}/Application") do
		sz.zip :files => FileList.new() \
					.include("**/*.dll") \
					.include("**/*.pdb") \
					.include("**/*.config") \
					.include("**/*.boo") \
					.exclude("obj")
	end
end

desc 'Deploys the build artifacts to the QA system'
task :deploy => :package do
	FileUtils.rm_rf configatron.deployment.location
	
	SevenZip.unzip \
		:tool => configatron.tools.zip,
		:zip_name => configatron.deployment.package,
		:destination => configatron.deployment.location
end

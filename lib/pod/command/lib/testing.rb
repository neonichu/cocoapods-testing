require 'xcodeproj'
require 'xctasks/test_task'

module Pod
  class Command
    class Lib

      # @todo Create a PR to add your plugin to CocoaPods/cocoapods.org
      #       in the `plugins.json` file, once your plugin is released.

      class Testing < Lib
        self.summary = 'Run tests for any pod from the command line without any prior knowledge.'

        def self.options
          [
            ['--dry-run', 'Show which tests would be executed.'],
            ['--verbose', 'Show full xcodebuild output.']
          ]
        end

        def initialize(argv)
          @@dry_run = argv.flag?('dry-run')
          @@verbose = argv.flag?('verbose')
          @@args = argv.arguments!

          @@found_projects = []
          @@found_tests = false
          super
        end

        def self.handle_projects_in_dir(dir)
          workspaces_in_dir(dir).each do |workspace_path|
            next if workspace_path.end_with?('.xcworkspace')

            project = Xcodeproj::Project.open(Pathname.new(workspace_path))
            yield project, workspace_path
          end
        end

        def self.handle_workspaces_in_dir(dir)
          workspaces_in_dir(dir).each do |workspace_path|
            next if workspace_path.end_with?('.xcodeproj')

            workspace = Xcodeproj::Workspace.new_from_xcworkspace(workspace_path)
            yield workspace, workspace_path
          end
        end

        :private

        def handle_xcode_artifacts_in_dir(dir)
          self.class.handle_workspaces_in_dir(dir) do |workspace, workspace_path|
            handle_workspace(workspace, workspace_path)
          end

          self.class.handle_projects_in_dir(dir) do |project, project_path|
            handle_project(project, project_path)
          end
        end

        def handle_project(project, project_location, workspace_location = nil)
          return if @@found_projects.include?(project_location)

          schemes = Dir[Xcodeproj::XCScheme.shared_data_dir(project_location).to_s + '/*']
          schemes += Dir[Xcodeproj::XCScheme.user_data_dir(project_location).to_s + '/*']

          scheme_map = Hash.new
          schemes.each do |path|
            next if File.directory?(path)
            doc = REXML::Document.new(File.new(path))
            REXML::XPath.each(doc, '//TestAction') do |action|
              blueprint_name = REXML::XPath.first(action, 
                '//BuildableReference/@BlueprintName').value
              scheme_name = File.basename(path, '.xcscheme')
              scheme_map[blueprint_name] = scheme_name
            end
          end

          project.targets.each do |target|
            product_type = nil

            begin
              product_type = target.product_type.to_s
            rescue
              next
            end

            if product_type.end_with?('bundle.unit-test')
              scheme = scheme_map[target.name]
              # Fallback to first scheme if none is found for this target
              next if not scheme_map.first
              scheme = scheme_map.first[1] unless scheme && scheme.length > 0
              @@found_projects << project_location
              run_tests(workspace_location || project_location, target.name, scheme)
            end
          end
        end

        def handle_workspace(workspace, workspace_location)
          workspace.file_references.each do |ref|
            ref_path = File.absolute_path(ref.path, Pathname.new(workspace_location).dirname)
            if ref_path.end_with?('.xcodeproj')
              if not File.exists? ref_path
                next
              end
              project = Xcodeproj::Project.open(ref_path)
              handle_project(project, ref_path, workspace_location)
            end
          end
        end

        def podspecs_to_check
          podspecs = Pathname.glob(Pathname.pwd + '*.podspec{.yaml,}')
          msg = 'Unable to find a podspec in the working directory'
          fail Informative, msg if podspecs.count.zero?
          podspecs
        end

        def run_tests(workspace, target_name, scheme_name)
          @@found_tests = true

          XCTasks::TestTask.new do |t|
            t.actions = %w(clean build test)
            t.runner = @@verbose ? :xcodebuild : :xcpretty

            if workspace.end_with? 'workspace'
              t.workspace   = workspace
            else
              t.project = workspace
            end

            t.actions << @@args unless @@args.nil?

            t.subtask(unit: scheme_name) do |s|
              # TODO: version should be configurable
              s.ios_versions = [versions.last]

              # TODO: simulator should be configurable
              if simulators && simulators.count > 0
                s.destination('name='+simulators.first)
              else
                s.destination('name=iPhone Retina (4-inch)')
              end
            end
          end

          UI.puts 'Running tests for ' + target_name
          Rake::Task['test:unit'].invoke unless @@dry_run
        end

        # TODO: Refactor to remove all projects which are part of a workspace
        def self.workspaces_in_dir(dir)
          glob_match = Dir.glob("#{dir}/**/*.xc{odeproj,workspace}")
          glob_match = glob_match.reject do |p|
            next true if p.include?('Pods.xcodeproj')
            next true if p.end_with?('.xcodeproj/project.xcworkspace')
            sister_workspace = p.chomp(File.extname(p.to_s)) + '.xcworkspace'
            p.end_with?('.xcodeproj') && glob_match.include?(sister_workspace)
          end
        end

        def simulators
          sims = `xcrun simctl list 2>/dev/null`.split("\n")
          sims = sims.select { |sim| sim[/Booted|Shutdown/] }
          sims.map { |sim| sim.gsub(/^\s+(.+?) \(.*/, '\1') }
        end

        def versions
          sdks = `xcodebuild -version -sdk 2>/dev/null`.split("\n")
          sdks = sdks.select { |sdk| sdk[/iphonesimulator/] }
          sdks.map { |sdk| sdk.gsub(/.*\(iphonesimulator(.*)\)/, '\1') }
        end

        def run
          podspecs_to_check.each do # |path|
            # TODO: How to link specs to projects/workspaces?
            # spec = Specification.from_file(path)

            handle_xcode_artifacts_in_dir(Pathname.pwd)

            Dir['*'].each do |dir| 
              next if !File.directory?(dir)
              original_dir = Pathname.pwd
              Dir.chdir(dir)

              handle_xcode_artifacts_in_dir(Pathname.pwd)

              Dir.chdir(original_dir)
            end

            if not @@found_tests
              puts('No suitable test targets found.'.yellow)
              exit(1)
            end
          end
        end
      end
    end
  end
end

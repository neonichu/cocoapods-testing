require 'xcodeproj'
require 'xctasks/test_task'

module Pod
  class Command
    class Lib

      # @todo Create a PR to add your plugin to CocoaPods/cocoapods.org
      #       in the `plugins.json` file, once your plugin is released.

      class Testing < Lib
        self.summary = 'Run tests for any pod from the command line without any prior knowledge.'

        def handle_workspace(workspace, workspace_location)
          workspace.file_references.each do |ref|
            if ref.path.end_with?('.xcodeproj')
              project = Xcodeproj::Project.open(ref.path)

              schemes = Dir[Xcodeproj::XCScheme.shared_data_dir(ref.path).to_s + '/*']
              schemes += Dir[Xcodeproj::XCScheme.user_data_dir(ref.path).to_s + '/*']

              scheme_map = Hash.new
              schemes.each do |path|
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
                  puts scheme_map

                  scheme = scheme_map[target.name]
                  run_tests(workspace_location, target.name, scheme)
                end
              end
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
          # TODO: Figure out what this was supposed to do:
          #   new(test: 'server:autostart')
          XCTasks::TestTask.new do |t|
            #t.runner      = :xcodebuild
            t.runner      = :xcpretty
            t.workspace   = workspace

            t.subtask(unit: scheme_name) do |s|
              # TODO: version should be configurable
              s.ios_versions = %w(7.1)
              s.destination('name=iPhone Retina (4-inch)')
            end
          end

          UI.puts 'Running tests for ' + target_name
          # puts Rake.application.tasks
          Rake::Task['test:unit'].invoke
        end

        def workspaces_in_dir(dir)
          glob_match = Dir.glob("#{dir}/**/*.xc{odeproj,workspace}")
          glob_match = glob_match.reject do |p|
            next true if p.include?('Pods.xcodeproj')
            next true if p.end_with?('.xcodeproj/project.xcworkspace')
            sister_workspace = p.chomp(File.extname(p.to_s)) + '.xcworkspace'
            p.end_with?('.xcodeproj') && glob_match.include?(sister_workspace)
          end
        end

        def run
          podspecs_to_check.each do # |path|
            # TODO: How to link specs to projects/workspaces?
            # spec = Specification.from_file(path)

            workspaces_in_dir(Pathname.pwd).each do |workspace|
              next if workspace.end_with?('.xcodeproj')

              wrkspace = Xcodeproj::Workspace.new_from_xcworkspace(workspace)
              handle_workspace(wrkspace, workspace)
            end
          end
        end
      end
    end
  end
end

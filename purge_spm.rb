require 'xcodeproj'
project = Xcodeproj::Project.open('NeuraLink.xcodeproj')

target = project.targets.find { |t| t.name == 'NeuraLink' }

# Find the specific product dependency by name
prod_dep = target.package_product_dependencies.find { |ref| ref.product_name == "llama" }
if prod_dep
  target.package_product_dependencies.delete(prod_dep)
  prod_dep.remove_from_project
end

# Find the specific package reference
pkg_ref = project.root_object.package_references.find { |pkg| pkg.respond_to?(:relative_path) && pkg.relative_path == "llama.cpp" }
if pkg_ref
  project.root_object.package_references.delete(pkg_ref)
  pkg_ref.remove_from_project
end

# Find any build files in the framework phase that reference it
target.frameworks_build_phase.files.each do |file|
  if file.product_ref && file.product_ref.respond_to?(:product_name) && file.product_ref.product_name == "llama"
    target.frameworks_build_phase.files.delete(file)
    file.remove_from_project
  end
end

project.save
puts "Purged all SPM llama references"

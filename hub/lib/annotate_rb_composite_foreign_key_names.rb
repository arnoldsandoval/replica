# AnnotateRb receives composite key columns as an array but sorts them with text.
# Convert the array to text before display.
module AnnotateRbCompositeForeignKeyNames
  def formatted_name
    name = super
    name.is_a?(Array) ? "[#{name.join(", ")}]" : name
  end
end

if defined?(AnnotateRb::ModelAnnotator::ForeignKeyAnnotation::ForeignKeyComponentBuilder)
  AnnotateRb::ModelAnnotator::ForeignKeyAnnotation::ForeignKeyComponentBuilder.prepend \
    AnnotateRbCompositeForeignKeyNames
end

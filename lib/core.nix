let
  inherit (builtins)
    all
    attrNames
    concatMap
    filter
    genericClosure
    groupBy
    getAttr
    hasAttr
    head
    isAttrs
    isList
    isPath
    isString
    length
    listToAttrs
    mapAttrs
    partition
    ;

  toList =
    value:
    if isList value then
      value
    else if value != null then
      [ value ]
    else if isAttrs value && value != { } then
      [ value ]
    else
      [ ];

  # Creates a unique reference used for building attribute sets from a category and name
  # Primarily allows `key` attribute to be used directly by `genericClosure` functions
  createReference = category: value: {
    key = "${category}:${toString value}";
    inherit category value;
  };

  # This is the prefix for all node metadata
  metadataKey = "_metadata";
in
{
  # Takes the lineage database as an input and outputs the built adjacency list and the strict categories from the database
  buildDB =
    input:
    let
      database = if (isString input || isPath input) then import input else input;

      strictCategories = database.strict or { };

      # Helper function that scans for nested attributes on categories (Grandchild Nodes)
      # Categories without grandchildren can be computed significantly faster as full graph traversal is not needed
      # This detects such nodes, providing a substantial runtime speedup depending on database nesting
      # Returns True if all children are leaf nodes or empty
      isFlat =
        category:

        # `all` iterates over every child node and returns true if all children nodes returned true
        all (
          child:

          # Metadata nodes don't count as child nodes
          if child == metadataKey then
            true
          else
            let
              childSubtree = category.${child};
            in
            if childSubtree ? ${metadataKey} then

              # If its a metadata node that doesnt have implied nodes (!(childSubtree.${metadataKey} ? implies))
              # And the metadata node is the only node (length (attrNames childSubtree) == 1)
              # Then return true
              !(childSubtree.${metadataKey} ? implies) && length (attrNames childSubtree) == 1
            else

              # Returns true if the child's subtree is empty (no grandchildren)
              childSubtree == { }

          # Iterates over all the nodes in the category
        ) (attrNames category);

      # Recursively flattens a nested category into an adjacency list
      # Lists are easier to append to than sets which is why we build this data structure with them
      flatten =
        category: parent: subtree:

        # Iterates over all the subtrees and returns a list with each of the results
        concatMap (
          nodeName:

          # Metadata nodes arent part of the tree structure but everything else is
          if nodeName == metadataKey then
            [ ]
          else
            let
              childNode = subtree.${nodeName};
              metadata = childNode.${metadataKey} or null;

              # Attribute set of the nodes names, edges and its attached modules
              node = {

                # `name` and `value` are the required inputs for listToAttrs which this is parsed into during adjacencySet
                name = nodeName;
                value = {
                  modules = toList (metadata.modules or null);

                  # Gets the list of edges this node points to
                  edges =
                    if isAttrs childNode then

                      # Builds an edge reference to the parent if it exists
                      toList (if parent != null then createReference category parent else null)
                      ++ (

                        # Builds an edge reference to implied nodes if they exists
                        if metadata ? implies then

                          # Return a list of all the implied categories by creating a reference for each implied node
                          concatMap (
                            impliedCategory: map (createReference impliedCategory) (toList metadata.implies.${impliedCategory})

                            # Iterate over the implied nodes
                          ) (attrNames metadata.implies)
                        else
                          [ ]
                      )
                    else
                      [ ];
                };
              };
            in

            # If the child node is the root of a subtree then return the node entry as well as
            # Recursively run this function where the current child node is the parent node of the next invocation
            # Keeps running recursively until it gets to a leaf node which returns its node entry
            if isAttrs childNode then [ node ] ++ flatten category nodeName childNode else [ node ]

          # Iterates over all the subtrees of the parent
        ) (attrNames subtree);

      # Returns the adjacency set of the entire database
      adjacencySet = mapAttrs (
        categoryName: categoryTree:

        # Already flat categories dont need much work done
        # This just iterates over them and adds any of their modules metadata
        # This also set the simple flag so genericClosure doesn't have to build the graph saving CPU time
        if isFlat categoryTree then
          {
            nodes = mapAttrs (_: node: {
              modules = toList (node.${metadataKey}.modules or null);
              edges = [ ];
            }) (removeAttrs categoryTree [ metadataKey ]);
            simple = true;
          }

        # Runs `flatten` on the category to get the flattened adjacency list of the tree
        # Converts the list output to a set for easier and faster lookup later
        else
          { nodes = listToAttrs (flatten categoryName null categoryTree); }

        # Iterates over the all categories in the database
      ) (strictCategories // removeAttrs database [ "strict" ]);
    in
    {

      # Exposes the adjacency set and strict categories
      inherit adjacencySet strictCategories;
    };

  # This takes the built lineage database and the host configuration as input
  # Traverses the database nodes to build the lineage traits
  # Creates the has helper function and exposes the nixos modules
  # Return a built lineage image with nixos modules, lineage traits and the has helper
  buildHost =
    { adjacencySet, strictCategories }:
    input:
    let
      host = if (isString input || isPath input) then import input else input;

      # Removing config keys to prevent them being read as categories
      # Because these are never used in graph building this is safe to do
      hostTraits = removeAttrs host [
        "modules"
        "imports"
      ];

      # Splits the traits by traits found in the `adjacencySet` categories and those not
      # The latter are not saved as a because they are only used once, while merging
      splitTraits = partition (trait: hasAttr trait adjacencySet) (attrNames hostTraits);
      traitsInDB = splitTraits.right;

      # References for host traits
      # Splits traits based on whether they are simple or need graph traversal
      splitReferences = partition (trait: !(adjacencySet.${trait.category}.simple or false)) (

        # Returns all the valid references
        # Iterates over all of the traits in the database
        concatMap (
          category:

          # Creates references for valid host trait values
          map (name: createReference category name) (
            filter (value: isString value || isPath value) (toList hostTraits.${category})
          )
        ) traitsInDB
      );

      # Builds the traits and groups them by their categories
      builtTraits = groupBy (getAttr "category") (
        let

          # These are the unresolved trait references that require graph building and traversal
          # The name `startSet` is also needed to be consumed by `genericClosure` so this cannot be renamed
          startSet = splitReferences.right;
        in
        (
          if startSet == [ ] then
            [ ]
          else

            # Uses `genericClosure` to iterate over the graph and build the trait references
            genericClosure {
              inherit startSet;
              operator =
                { category, value, ... }:

                # Finds the current node in the adjacency set
                # Throws an error if the node is not found in a strict category
                # Otherwise if the node is not found returns an empty list
                adjacencySet.${category}.nodes.${value}.edges or (
                  if hasAttr category strictCategories then
                    throw "Lineage: item '${value}' not found in strict category '${category}'"
                  else
                    [ ]
                );
            }
        )

        # Adds the simple categories as is without any graph traversal
        ++ splitReferences.wrong
      );

      foundCategories = attrNames builtTraits;

      # The final attribute set of resolved lineage traits for the given system
      # This is passed directly into the final lineage object as `lineage.traits`
      traits = listToAttrs (

        # Iterates over all the hostfile's categories
        map (
          category:
          let

            built = hasAttr category builtTraits;

            # Gets all the built traits from `builtTraits`
            allTraits =
              if built then

                # Gets the unresolved extra traits from the host system
                filter (trait: !(isString trait || isPath trait)) (toList (hostTraits.${category} or null))

                # Gets the built traits from `builtTraits`
                ++ (map (getAttr "value") (toList builtTraits.${category}))
              else
                [ ];

            value =

              # If the trait was built by `builtTraits` process it accordingly
              if built then

                # Unwraps single-element lists for categories not tracked in the database
                if hasAttr category adjacencySet || (length allTraits) > 1 then allTraits else head allTraits

              # Otherwise just return the key and value pair from the hostfile
              else
                hostTraits.${category};
          in
          {
            inherit value;
            name = category;
          }
        ) (splitTraits.wrong ++ foundCategories)
      );

      # A attribute set lookup table for has for O(1) lookup
      hasLookup = mapAttrs (
        _: values:

        # Builds an attribute set where every value in the system traits is assigned `true`
        listToAttrs (
          map (name: {
            inherit name;
            value = true;
          }) (toList values)
        )
      ) traits;

      # This is the final lineage object containing the resolved traits, the NixOS modules, and the `has` helper
      lineage = {
        inherit traits;

        # Adds the
        hostModule = {

          # All the nixos modules to import into the system
          # `imports` name cannot be changed as it is used to directly import nixos modules using `inherit`
          imports =

            # Modules defined in the hostfile
            (toList (host.modules or null))
            ++ (toList (host.imports or null))

            # Modules from the metadata of resolved nodes
            # Checks over all the categories
            ++ concatMap (
              category:

              # Gets the list of NixOS modules for each resolved trait in the category
              concatMap (
                trait: adjacencySet.${category}.nodes.${trait.value}.modules or [ ]
              ) builtTraits.${category}
            ) foundCategories;

          # Exposes the lineage object to all NixOS modules via `options.lineage`
          _module.args.lineage = lineage;
        };

        # Helper to check if an item is in that categories traits
        has = mapAttrs (
          category: _: item:

          # Checks the lookup set for the item specified
          hasAttr item (hasLookup.${category} or { })
        ) adjacencySet;
      };
    in
    {
      inherit lineage;
    };
}

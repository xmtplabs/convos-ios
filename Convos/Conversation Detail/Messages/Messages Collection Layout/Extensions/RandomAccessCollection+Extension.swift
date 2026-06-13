import Foundation

extension RandomAccessCollection where Index == Int {
    func binarySearch(predicate: (Element) -> ComparisonResult) -> Index? {
        var lowerBound = startIndex
        var upperBound = endIndex

        while lowerBound < upperBound {
            let midIndex: Int = lowerBound &+ (upperBound &- lowerBound) / 2
            let result: ComparisonResult = predicate(self[midIndex])
            if result == .orderedSame {
                return midIndex
            } else if result == .orderedAscending {
                lowerBound = midIndex &+ 1
            } else {
                upperBound = midIndex
            }
        }
        return nil
    }

    func binarySearchRange(predicate: (Element) -> ComparisonResult) -> [Element] {
        func leftMostSearch(lowerBound: Index, upperBound: Index) -> Index? {
            var lowerBound = lowerBound
            var upperBound = upperBound

            while lowerBound < upperBound {
                let midIndex: Int = (lowerBound &+ upperBound) / 2
                if predicate(self[midIndex]) == .orderedAscending {
                    lowerBound = midIndex &+ 1
                } else {
                    upperBound = midIndex
                }
            }
            if predicate(self[lowerBound]) == .orderedSame {
                return lowerBound
            } else {
                return nil
            }
        }

        func rightMostSearch(lowerBound: Index, upperBound: Index) -> Index? {
            var lowerBound = lowerBound
            var upperBound = upperBound

            while lowerBound < upperBound {
                let midIndex: Int = (lowerBound &+ upperBound &+ 1) / 2
                if predicate(self[midIndex]) == .orderedDescending {
                    upperBound = midIndex &- 1
                } else {
                    lowerBound = midIndex
                }
            }
            if predicate(self[lowerBound]) == .orderedSame {
                return lowerBound
            } else {
                return nil
            }
        }

        guard !isEmpty,
              let lowerBound = leftMostSearch(lowerBound: startIndex, upperBound: endIndex - 1),
              let upperBound = rightMostSearch(lowerBound: startIndex, upperBound: endIndex - 1) else {
            return []
        }

        return Array(self[lowerBound...upperBound])
    }
}
